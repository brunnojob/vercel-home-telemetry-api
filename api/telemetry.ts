import { timingSafeEqual } from "node:crypto";
import { neon } from "@neondatabase/serverless";
import type { VercelRequest, VercelResponse } from "@vercel/node";

type Payload = {
  deviceId?: unknown;
  temperatureC?: unknown;
  humidityPct?: unknown;
  soilMoisture?: unknown;
  eventAt?: unknown;
};

function authorized(req: VercelRequest, envName: string): boolean {
  const expected = process.env[envName];
  const header = req.headers.authorization;
  if (!expected || typeof header !== "string" || !header.startsWith("Bearer ")) return false;
  const supplied = Buffer.from(header.slice(7));
  const actual = Buffer.from(expected);
  return supplied.length === actual.length && timingSafeEqual(supplied, actual);
}

function validNumber(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= min && value <= max;
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const read = req.method === "GET";
  if (!authorized(req, read ? "ADMIN_TOKEN" : "DEVICE_TOKEN"))
    return res.status(401).json({ error: "unauthorized" });
  if (!process.env.DATABASE_URL) return res.status(503).json({ error: "database_unavailable" });
  const sql = neon(process.env.DATABASE_URL);

  if (req.method === "POST") {
    const body = req.body as Payload;
    if (!body || typeof body.deviceId !== "string" || !/^[a-zA-Z0-9_-]{1,64}$/.test(body.deviceId))
      return res.status(400).json({ error: "invalid_device_id" });
    const temperature = body.temperatureC === undefined ? null : body.temperatureC;
    const humidity = body.humidityPct === undefined ? null : body.humidityPct;
    const moisture = body.soilMoisture === undefined ? null : body.soilMoisture;
    if (temperature === null && humidity === null && moisture === null)
      return res.status(400).json({ error: "measurement_required" });
    if ((temperature !== null && !validNumber(temperature, -40, 85)) ||
        (humidity !== null && !validNumber(humidity, 0, 100)) ||
        (moisture !== null && !validNumber(moisture, 0, 4095)))
      return res.status(400).json({ error: "measurement_out_of_range" });
    if (body.eventAt !== undefined &&
        (typeof body.eventAt !== "string" || !Number.isFinite(Date.parse(body.eventAt))))
      return res.status(400).json({ error: "invalid_event_at" });
    const eventAt = typeof body.eventAt === "string" ? new Date(body.eventAt).toISOString() : new Date().toISOString();
    const rows = await sql`INSERT INTO device_telemetry (device_id, temperature_c, humidity_pct, soil_moisture, event_at)
      VALUES (${body.deviceId}, ${temperature}, ${humidity}, ${moisture}, ${eventAt})
      RETURNING id, device_id, temperature_c, humidity_pct, soil_moisture, event_at`;
    return res.status(201).json(rows[0]);
  }

  if (req.method === "GET") {
    const deviceId = typeof req.query.deviceId === "string" ? req.query.deviceId : "";
    if (!/^[a-zA-Z0-9_-]{1,64}$/.test(deviceId)) return res.status(400).json({ error: "invalid_device_id" });
    const parsed = Number(req.query.limit ?? 100);
    const limit = Number.isInteger(parsed) ? Math.max(1, Math.min(parsed, 500)) : 100;
    const rows = await sql`SELECT id, device_id, temperature_c, humidity_pct, soil_moisture, event_at
      FROM device_telemetry WHERE device_id = ${deviceId}
      ORDER BY event_at DESC LIMIT ${limit}`;
    return res.status(200).json({ items: rows });
  }

  res.setHeader("Allow", "GET, POST");
  return res.status(405).json({ error: "method_not_allowed" });
}
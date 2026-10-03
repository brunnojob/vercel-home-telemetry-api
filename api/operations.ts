import { timingSafeEqual } from "node:crypto";
import { neon } from "@neondatabase/serverless";
import type { VercelRequest, VercelResponse } from "@vercel/node";

function authorized(req: VercelRequest): boolean {
  const expected = process.env.ADMIN_TOKEN;
  const header = req.headers.authorization;
  if (!expected || typeof header !== "string" || !header.startsWith("Bearer ")) return false;
  const provided = Buffer.from(header.slice(7));
  const configured = Buffer.from(expected);
  return provided.length === configured.length && timingSafeEqual(provided, configured);
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!authorized(req)) return res.status(401).json({ error: "unauthorized" });
  if (!process.env.DATABASE_URL) return res.status(503).json({ error: "database_unavailable" });
  const sql = neon(process.env.DATABASE_URL);

  if (req.method === "GET") {
    const telemetry = await sql`SELECT device_id, temperature_c, humidity_pct, soil_moisture, event_at
      FROM device_telemetry ORDER BY event_at DESC LIMIT 100`;
    const workOrders = await sql`SELECT id, asset_tag, title, priority, status, created_at, updated_at
      FROM work_orders ORDER BY
      CASE status WHEN 'open' THEN 0 WHEN 'acknowledged' THEN 1 ELSE 2 END, created_at DESC LIMIT 100`;
    return res.status(200).json({ telemetry, workOrders });
  }

  if (req.method === "POST") {
    const body = req.body as Record<string, unknown> | null;
    if (!body || typeof body !== "object") return res.status(400).json({ error: "invalid_payload" });
    if (body.action === "transition") {
      const id = Number(body.id);
      const next = body.status;
      if (!Number.isInteger(id) || id < 1 || (next !== "acknowledged" && next !== "closed"))
        return res.status(400).json({ error: "invalid_transition" });
      const prior = next === "acknowledged" ? "open" : "acknowledged";
      const rows = await sql`UPDATE work_orders SET status = ${next}, updated_at = NOW()
        WHERE id = ${id} AND status = ${prior}
        RETURNING id, asset_tag, title, priority, status, updated_at`;
      if (!rows.length) return res.status(409).json({ error: "work_order_state_conflict" });
      return res.status(200).json(rows[0]);
    }
    const assetTag = body.assetTag;
    const title = body.title;
    const priority = body.priority;
    if (typeof assetTag !== "string" || !/^[A-Z0-9_-]{1,32}$/.test(assetTag) ||
        typeof title !== "string" || title.trim().length < 4 || title.length > 160 ||
        !["low", "medium", "high", "critical"].includes(String(priority)))
      return res.status(400).json({ error: "invalid_work_order" });
    const rows = await sql`INSERT INTO work_orders (asset_tag, title, priority)
      VALUES (${assetTag}, ${title.trim()}, ${priority})
      RETURNING id, asset_tag, title, priority, status, created_at, updated_at`;
    return res.status(201).json(rows[0]);
  }

  res.setHeader("Allow", "GET, POST");
  return res.status(405).json({ error: "method_not_allowed" });
}
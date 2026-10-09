import type { VercelRequest, VercelResponse } from '@vercel/node';
import { ApiError, bodyObject, boundedInteger, database, principal, sendError } from '../lib/supabase.mjs';

export default async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader('Cache-Control', 'no-store');
  try {
    if (!['GET', 'POST'].includes(req.method ?? '')) throw new ApiError(405, 'method_not_allowed');
    const { token, ownerId } = await principal(req);
    if (req.method === 'GET') {
      const device = req.query.deviceId;
      if (typeof device !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(device)) throw new ApiError(400, 'invalid_device_id');
      const limit = boundedInteger(req.query.limit, 100, 500);
      return res.status(200).json({ items: await database(token, `bd_telemetry?device_id=eq.${device}&order=event_at.desc&limit=${limit}`) });
    }
    const body = bodyObject(req.body, 8192);
    if (typeof body.deviceId !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(body.deviceId)) throw new ApiError(400, 'invalid_device_id');
    const ranges = { temperatureC: [-40, 85], humidityPct: [0, 100], soilMoisture: [0, 4095] };
    let count = 0;
    for (const [key, [min, max]] of Object.entries(ranges)) {
      const value = body[key];
      if (value === undefined || value === null) continue;
      if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max ||
          (key === 'soilMoisture' && !Number.isInteger(value))) throw new ApiError(400, 'measurement_out_of_range');
      count++;
    }
    if (!count) throw new ApiError(400, 'measurement_required');
    const eventAt = body.eventAt === undefined ? Date.now() : Date.parse(body.eventAt);
    if (!Number.isFinite(eventAt) || eventAt > Date.now() + 60000) throw new ApiError(400, 'invalid_event_at');
    const rows = await database(token, 'bd_telemetry', { method: 'POST', body: JSON.stringify({
      owner_id: ownerId, device_id: body.deviceId, temperature_c: body.temperatureC ?? null,
      humidity_pct: body.humidityPct ?? null, soil_moisture: body.soilMoisture ?? null,
      event_at: new Date(eventAt).toISOString()
    }) });
    return res.status(201).json(rows[0]);
  } catch (error) { return sendError(res, error); }
}

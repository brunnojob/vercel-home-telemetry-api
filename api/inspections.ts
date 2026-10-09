import type { VercelRequest, VercelResponse } from '@vercel/node';
import { ApiError, bodyObject, database, principal, sendError } from '../lib/supabase.mjs';

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, nested]) => `${JSON.stringify(key)}:${canonical(nested)}`).join(',')}}`;
  return JSON.stringify(value);
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader('Cache-Control', 'no-store');
  try {
    if (req.method !== 'POST') throw new ApiError(405, 'method_not_allowed');
    const { token, ownerId } = await principal(req);
    const body = bodyObject(req.body, 40000);
    if (typeof body.recordId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.recordId) ||
        typeof body.formId !== 'string' || !/^[a-zA-Z0-9_-]{1,48}$/.test(body.formId) ||
        typeof body.assetTag !== 'string' || !/^[A-Z0-9_-]{1,32}$/.test(body.assetTag)) throw new ApiError(400, 'invalid_inspection_record');
    bodyObject(body.answers, 32000);
    if (body.capturedAt !== undefined && typeof body.capturedAt !== 'string') throw new ApiError(400, 'invalid_capture_time');
    const capturedAt = body.capturedAt === undefined ? Date.now() : Date.parse(body.capturedAt);
    if (!Number.isFinite(capturedAt) || capturedAt > Date.now() + 60000) throw new ApiError(400, 'invalid_capture_time');
    const data = { owner_id: ownerId, record_id: body.recordId, form_id: body.formId, asset_tag: body.assetTag,
      answers: body.answers, captured_at: new Date(capturedAt).toISOString() };
    const rows = await database(token, 'bd_inspections?on_conflict=owner_id,record_id', {
      method: 'POST', headers: { Prefer: 'resolution=ignore-duplicates,return=representation' }, body: JSON.stringify(data)
    });
    if (rows.length) return res.status(201).json(rows[0]);
    const previous = await database(token, `bd_inspections?record_id=eq.${body.recordId}&limit=1`);
    const prior = previous[0];
    if (!prior || prior.asset_tag !== data.asset_tag || prior.form_id !== data.form_id ||
        canonical(prior.answers) !== canonical(data.answers) || (body.capturedAt !== undefined && Date.parse(prior.captured_at) !== capturedAt))
      throw new ApiError(409, 'idempotency_conflict');
    return res.status(200).json({ duplicate: true, recordId: body.recordId });
  } catch (error) { return sendError(res, error); }
}

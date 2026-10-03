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
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "method_not_allowed" });
  }
  if (!authorized(req)) return res.status(401).json({ error: "unauthorized" });
  if (!process.env.DATABASE_URL) return res.status(503).json({ error: "database_unavailable" });
  const body = req.body as Record<string, unknown> | null;
  if (!body || typeof body !== "object" || typeof body.recordId !== "string" ||
      !/^[a-f0-9-]{36}$/i.test(body.recordId) || typeof body.formId !== "string" ||
      !/^[a-z0-9_-]{1,48}$/i.test(body.formId) || typeof body.assetTag !== "string" ||
      !/^[A-Z0-9_-]{1,32}$/.test(body.assetTag) || !body.answers ||
      typeof body.answers !== "object" || Array.isArray(body.answers))
    return res.status(400).json({ error: "invalid_inspection_record" });
  if (Buffer.byteLength(JSON.stringify(body.answers), "utf8") > 32000)
    return res.status(413).json({ error: "answers_too_large" });

  const sql = neon(process.env.DATABASE_URL);
  const rows = await sql`INSERT INTO inspection_records (record_id, form_id, asset_tag, answers, captured_at)
    VALUES (${body.recordId}, ${body.formId}, ${body.assetTag}, ${JSON.stringify(body.answers)}::jsonb,
      ${typeof body.capturedAt === "string" && Number.isFinite(Date.parse(body.capturedAt))
        ? new Date(body.capturedAt).toISOString() : new Date().toISOString()})
    ON CONFLICT (record_id) DO NOTHING
    RETURNING record_id, asset_tag, captured_at, received_at`;
  if (!rows.length) return res.status(200).json({ duplicate: true, recordId: body.recordId });
  return res.status(201).json(rows[0]);
}
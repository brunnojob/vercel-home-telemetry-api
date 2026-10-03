# vercel-home-telemetry-api

Vercel Node.js API for ESP32 household telemetry. Supports authenticated `POST /api/telemetry` ingestion and `GET /api/telemetry?deviceId=...&limit=100` history reads. Measurements are validated and stored in PostgreSQL through Neon.

Set `DATABASE_URL` and `DEVICE_TOKEN` in Vercel project environment variables. Apply `schema.sql` to the database. Configure environment variables locally, then run `npm install`, `npm run typecheck`, and `npm run dev`.

Send a JSON body with `deviceId` and optional `temperatureC`, `humidityPct`, `soilMoisture`, and ISO-8601 `eventAt`. Send the token in `Authorization: Bearer ...`. Never commit tokens or database URLs.

Project by [Brunno Dev](https://brunnodev.store).
# vercel-home-telemetry-api

Vercel Node.js API for ESP32 household telemetry. `POST /api/telemetry` validates and stores readings in PostgreSQL through Neon. `GET /api/telemetry?deviceId=...&limit=100` reads bounded history with separate admin authorization.

Set `DATABASE_URL`, `DEVICE_TOKEN` and `ADMIN_TOKEN` in Vercel environment variables. Apply `schema.sql`. Run `npm install`, `npm run typecheck`, and `npm run dev` locally after setting those values. Never commit secrets.

POST requires `Authorization: Bearer $DEVICE_TOKEN` and JSON with a `deviceId` plus at least one of `temperatureC`, `humidityPct`, or `soilMoisture`. GET requires `$ADMIN_TOKEN`. Measurement ranges are validated before insert.

Project by [Brunno Dev](https://brunnodev.store).
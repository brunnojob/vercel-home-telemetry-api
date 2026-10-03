# offshore-scada-operations | Brunno Dev

Full-stack operations workspace for field equipment and process signals. The Vercel Node.js API validates device telemetry, shows recent readings, manages work-order state transitions, and accepts idempotent inspection submissions. The browser dashboard shows readings and maintenance work; the low-code inspection page lets operators define field layouts, collect offline in IndexedDB, and synchronize records later. A service worker caches the app shell for field use without network access.

## Stack

- Vercel Functions with TypeScript
- Neon PostgreSQL
- HTML, CSS and browser JavaScript
- ESP32 serial/telemetry prototypes in the companion repositories

## Setup

Configure `DATABASE_URL`, `DEVICE_TOKEN`, and `ADMIN_TOKEN` as Vercel environment variables. Apply `schema.sql` to the PostgreSQL database. Install dependencies with `npm install`, check types with `npm run typecheck`, and run locally with `npm run dev`.

Open `/` for the SCADA-style dashboard and `/inspections.html` for the low-code inspection builder. Install it to the device home screen for faster field access; inspection records remain queued in IndexedDB until an operator synchronizes them. The dashboard uses `ADMIN_TOKEN` only in memory in the active tab. `POST /api/telemetry` accepts device readings using `DEVICE_TOKEN`; `GET /api/operations` and work-order actions use `ADMIN_TOKEN`; `POST /api/inspections` syncs offline records with `ADMIN_TOKEN`. Do not put tokens in browser storage or source control.

This is an operational prototype. Validate sensor calibration, alarm thresholds, network behavior and site-specific safety procedures before connecting it to live equipment. The software does not command safety-critical machinery.

[brunnodev.store](https://brunnodev.store)
# Operations Archive

An API and interface for storing execution results, telemetry, inspections, and work orders. It uses PostgreSQL on Supabase, per-user authentication, and Vercel Functions.

## Run

```sh
npm ci
npm test
npm run typecheck
npm run dev
```

Set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. A service key is not required. Versioned migrations are in `supabase/migrations` and use the `bd_` prefix.

## Workflows

- `/laboratory.html`: registration, authentication, result imports, and queries by project.
- `/`: telemetry and work orders.
- `/inspections.html`: inspection forms.
- `POST /api/runs`: records a result and its events in a transaction with an idempotency key.
- `GET /api/runs?project=name`: returns up to 200 records owned by the authenticated user.
- `/api/telemetry`, `/api/operations`, and `/api/inspections`: validation, persistence, and ownership checks.

RLS policies isolate users. Results and events are immutable. Work orders have controlled transitions. Inventory movements and accounting entries require a revision and update their balances in the same transaction.

## Native clients

```sh
python cloud/sync.py enqueue result.json --project c-household-budget
python cloud/sync.py sync
python -m unittest discover -s cloud
```

Set `BRUNNODEV_ACCESS_TOKEN` to your session token. `BRUNNODEV_API_URL` selects an alternative HTTPS endpoint. The client retains reports in a SQLite queue until the server confirms persistence; retries do not duplicate records. Only a JSON object containing `"persisted": true` is accepted as confirmation. Other responses retain the report and schedule a retry.

No demonstration records are inserted automatically. Sensors, payments, and vision models depend on their respective devices and providers.

## License

Original source and documentation are MIT licensed; see [LICENSE](LICENSE). Third-party dependencies and media retain their respective terms. Maintained by [Brunno Dev](https://brunnodev.store).

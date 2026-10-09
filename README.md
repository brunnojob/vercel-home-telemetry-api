# Operations Archive

An API and interface for storing execution results, telemetry, inspections, and work orders. It uses PostgreSQL on Supabase, per-user authentication, and compatible serverless hosting Functions.

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

## Implementation update

The [C17 archive client](clients/c/README.md) provides durable native report submission with file locking, content-derived idempotency keys, bounded HTTPS requests and exact receipt matching. Netlify functions expose the existing authenticated API; receipts include the submitted client key. The static build publishes only selected web assets. Run `node --test tests/*.test.mjs` and `make -C clients/c test`.

Contribution trailer: `Co-authored-by: nyctophile <33561761+ineedfoundmyway@users.noreply.github.com>`.

## Native archive clients

Ruby uses only its standard library. It provides process locking, an atomic file outbox, bounded input and responses, retry backoff, HTTPS peer verification, redirect refusal, and persisted receipt checks:

```sh
ruby cloud/test_outbox.rb
ruby cloud/outbox.rb enqueue c-household-budget result.json
ruby cloud/outbox.rb sync
```

Swift uses Foundation and CryptoKit on macOS 12 or later. Its actor serializes local queue access within one process; run one CLI process per queue directory. It checks immutable idempotency payloads, bounds queue capacity, refuses HTTP redirects, and retains retries and receipts across restarts:

```sh
swiftc -parse-as-library cloud/ArchiveOutbox.swift -o archive-client
./archive-client --self-test
./archive-client enqueue android-offshore-field-console result.json
./archive-client sync
```

Both use `BRUNNODEV_API_URL`, `BRUNNODEV_ACCESS_TOKEN` and optional `BRUNNODEV_OUTBOX`. Session tokens stay in memory and are never written into queue records. Ruby and Swift queues are separate formats; use separate directories. Native clients have a dedicated GitHub Actions workflow.

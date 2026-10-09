# Native Operations Archive Client

C17 command-line client for durable submission of JSON reports to the Supabase-backed operations API. Reports remain on disk until an HTTPS response contains `persisted: true` and the exact `clientKey` of the queued report. A directory lock serializes queue access across processes.

## Build and verify

Install a C17 compiler, Make, libcurl, OpenSSL and cJSON development headers.

```sh
make
make test
```

## Queue and synchronize

```sh
./archive enqueue ./outbox cpp-water-leak-alarm ./report.json
export BRUNNODEV_API_URL=https://YOUR-SITE.netlify.app/api/runs
export BRUNNODEV_ACCESS_TOKEN=YOUR_SUPABASE_USER_ACCESS_TOKEN
./archive sync ./outbox
```

Use a signed-in user's access token. Keep credentials in the environment. The API uses Supabase Row Level Security to associate reports with that user. Never place a service-role key in a native client or public repository.

The queue deduplicates identical project/report content with SHA-256. Payloads, queue size, HTTP response size and delivery batches are bounded. Failed or mismatched acknowledgements remain pending; run `sync` again to retry. The client does not automatically schedule retries.

Credits: [brunnodev.store](https://brunnodev.store). See the repository license.

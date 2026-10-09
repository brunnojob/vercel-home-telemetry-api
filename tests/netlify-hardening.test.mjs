import test from "node:test";
import assert from "node:assert/strict";
import { adapt } from "../lib/netlify-adapter.mjs";
import runs from "../api/runs.mjs";

test("Netlify preserves authentication denial and response headers", async () => {
  const response = await adapt(runs)(new Request("https://site.example/api/runs?project=test"));
  assert.equal(response.status, 401);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(await response.json(), { error: "supabase_session_required" });
});

test("ambiguous query parameters never reach a handler", async () => {
  const response = await adapt(() => { assert.fail("handler invoked"); })(new Request("https://site.example/api/runs?limit=1&limit=200"));
  assert.equal(response.status, 400);
});

test("streamed body limits apply without Content-Length", async () => {
  const response = await adapt(() => { assert.fail("handler invoked"); }, 20)(new Request("https://site.example/api/runs", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ data: "x".repeat(100) }) }));
  assert.equal(response.status, 413);
});

test("malformed JSON and unsupported content are rejected", async () => {
  const handler = adapt(() => { assert.fail("handler invoked"); });
  assert.equal((await handler(new Request("https://site.example/api", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{" }))).status, 400);
  assert.equal((await handler(new Request("https://site.example/api", { method: "POST", body: "{}" }))).status, 415);
});

test("status, user token, query and parsed payload survive adaptation", async () => {
  const handler = adapt((req, res) => {
    assert.equal(req.headers.authorization, "Bearer user-token");
    assert.equal(req.query.project, "native-project");
    res.status(201).json({ persisted: req.body.ok });
  });
  const response = await handler(new Request("https://site.example/api?project=native-project", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer user-token" }, body: '{"ok":true}' }));
  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), { persisted: true });
});

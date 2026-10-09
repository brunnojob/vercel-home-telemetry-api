export function adapt(handler, maxBytes = 262144) {
  return async function (request) {
    const headers = new Headers({
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "strict-origin-when-cross-origin",
    });
    const fail = (status, error) => Response.json({ error }, { status, headers });
    try {
      const url = new URL(request.url);
      const query = Object.create(null);
      for (const [key, value] of url.searchParams) {
        if (Object.hasOwn(query, key)) return fail(400, "duplicate_query_parameter");
        query[key] = value;
      }
      let body;
      if (request.body) {
        if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get("Content-Type") ?? ""))
          return fail(415, "json_required");
        const declared = request.headers.get("Content-Length");
        if (declared && (!/^\d+$/.test(declared) || Number(declared) > maxBytes))
          return fail(413, "payload_too_large");
        const reader = request.body.getReader();
        const chunks = [];
        let length = 0;
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            length += value.byteLength;
            if (length > maxBytes) {
              await reader.cancel();
              return fail(413, "payload_too_large");
            }
            chunks.push(value);
          }
        } finally {
          reader.releaseLock();
        }
        const buffer = new Uint8Array(length);
        let offset = 0;
        for (const chunk of chunks) {
          buffer.set(chunk, offset);
          offset += chunk.byteLength;
        }
        try {
          body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(buffer));
        } catch {
          return fail(400, "invalid_json");
        }
      }
      let status = 200;
      let result;
      const res = {
        setHeader(key, value) { headers.set(key, String(value)); return this; },
        status(value) { status = value; return this; },
        json(value) { result = value; return this; },
      };
      await handler({ method: request.method, headers: Object.fromEntries(request.headers), query, body }, res);
      return Response.json(result ?? null, { status, headers });
    } catch {
      return fail(502, "upstream_unavailable");
    }
  };
}

# Loom SDK v2 — additions

**Status**: backend implemented 2026-06-02 (this commit). Frontend
`./platform` SDK in the loom UI repo needs to be updated to match — see
"Frontend changes required" below.

---

## What's new

4 capabilities exposed through `./platform`, each backed by a new
endpoint under `/loom/api/<ws>/<sid>/...`. Whitelist-driven where
relevant: AI-generated pages can only reach pre-configured presets /
tools, not arbitrary URLs / commands.

| API | Endpoint | Whitelist |
|---|---|---|
| `platform.uploadFile(file, opts?)` | `POST /upload` (multipart) | size + MIME blocklist |
| `platform.openResource(uri)` | `GET /resource?uri=...` | URI must be `resource://uploads/<this_ws>/...` |
| `platform.fetch(preset, url, init?)` | `POST /fetch` | `:fetch_presets` config (URL regex + methods + body cap) |
| `platform.tool(name, args)` | `POST /tool` | `:tools` config (registered modules) |

The existing v1 (`sendMessage` / `onMessage` / `getHistory`) is
unchanged. v2 is **purely additive**.

---

## Endpoint reference (server-side authoritative)

### `POST /loom/api/:ws/:sid/upload`

- Body: `multipart/form-data` with a `file` field (the File blob).
  Optional `kind` text field for caller-side categorization.
- Limits enforced server-side: 20 MB max; MIME blocklist
  `application/x-msdownload`, `application/x-msdos-program`;
  extension blocklist `.exe .bat .cmd .sh .com .scr .ps1`.
- Storage: copied to `Ezagent.Home.path("uploads")/<uuid>-<safe-name>`
  — the same dir the admin chat upload uses.
- Response:
  ```json
  { "ok": true,
    "uri": "resource://uploads/system/abc123-resume.pdf",
    "name": "resume.pdf",
    "size": 38912,
    "mime": "application/pdf" }
  ```
  or `{ "ok": false, "error": "file_too_large" | "ext_blocked" | ... }`.

### `GET /loom/api/:ws/:sid/resource?uri=<encoded resource URI>`

- The URI must be a `resource://uploads/<ws>/<filename>` with `<ws>`
  matching the path's `:ws` param. Cross-workspace access returns 400.
- Response: 302 redirect to `/files/<filename>` (the canonical
  `EzagentWeb.UploadsController` download endpoint). That controller
  enforces per-uploader / per-session-member authz; for loom UI's
  temp user it should succeed for uploads done in this session.
- Non-resource URIs / malformed → 400 with `{ "ok": false, "error": ... }`.

### `POST /loom/api/:ws/:sid/fetch`

- Body:
  ```json
  { "preset": "public",
    "url": "https://api.github.com/repos/elixir-lang/elixir",
    "method": "GET",
    "headers": { "accept": "application/json" },
    "body": "" }
  ```
- The preset is looked up in `Application.get_env(:ezagent_plugin_loom,
  :fetch_presets)`. Default `public` preset allows GitHub API +
  httpbin + jsonplaceholder for smoke testing.
- Each preset declares:
  - `url`: anchored regex the request URL must match
  - `methods`: allowed HTTP methods (atoms `:get`, `:post`, ...)
  - `max_body`: response body truncated past this size (default 100 KB)
  - `timeout_ms`: request + connect timeout (default 8 000)
  - `headers`: server-injected headers, plain map or
    `{:env, "VAR_NAME"}` tuples (secrets resolved at call time so
    they're not baked into compiled code)
- Caller headers are restricted to:
  `content-type`, `accept`, `accept-language`, `user-agent`. Other
  caller headers are silently dropped. Preset headers override caller.
- No redirects followed (SSRF guard).
- Response:
  ```json
  { "ok": true,
    "status": 200,
    "headers": { "content-type": "application/json", ... },
    "body": "<stringified body>",
    "truncated": false }
  ```
  Failures: `{"ok": false, "error": "unknown_preset" | "url_not_allowed" |
  "method_not_allowed" | "request_body_too_large" | "connect_failed" |
  "timeout" | "request_failed" }`.

### `POST /loom/api/:ws/:sid/tool`

- Body: `{ "name": "now", "args": { "tz": "Asia/Shanghai" } }`
- Tools are modules implementing `EzagentPluginLoom.Tool`, registered
  via `Application.get_env(:ezagent_plugin_loom, :tools, [])` at boot.
- Each tool gets a ctx map: `%{ws, sid, session_uri, caller}`.
- Response: `{ "ok": true, "result": <JSON-encodable> }` or
  `{ "ok": false, "error": "<reason>" }`.

---

## Frontend changes required

The vendored `priv/static/loom_ui/` is compiled from the loom UI
repo. To complete this feature, the UI repo's `./platform` SDK
(formerly `lib/sandbox/platform-sdk.ts`) needs:

### New SDK methods

```ts
// Add to platform-sdk.ts public exports.

export async function uploadFile(file: File, opts?: { kind?: string }):
  Promise<{ ok: boolean; uri?: string; name?: string; size?: number;
            mime?: string; error?: string }> {
  const form = new FormData();
  form.append('file', file);
  if (opts?.kind) form.append('kind', opts.kind);
  // Bridge: host postMessages this to /loom/api/:ws/:sid/upload (multipart).
  return rpcCall('uploadFile', { form });
}

export async function openResource(uri: string):
  Promise<{ ok: boolean; url?: string; error?: string }> {
  // Bridge does GET /loom/api/:ws/:sid/resource?uri=<encoded> and
  // resolves to the 302's Location (i.e. the /files/<name> URL).
  return rpcCall('openResource', { uri });
}

export async function fetch(preset: string, url: string,
  init?: { method?: string; headers?: Record<string,string>;
           body?: string }):
  Promise<{ ok: boolean; status?: number; headers?: Record<string,string>;
            body?: string; truncated?: boolean; error?: string }> {
  return rpcCall('fetch', { preset, url, ...(init || {}) });
}

export async function tool(name: string, args: object):
  Promise<{ ok: boolean; result?: any; error?: string }> {
  return rpcCall('tool', { name, args });
}
```

### New postMessage frame types (sandbox → host)

```ts
type SandboxRPC =
  | { type: 'sendMessage'; correlationId: string; text: string }   // v1 (existing)
  | { type: 'getHistory'; correlationId: string }                  // v1 (existing)
  | { type: 'uploadFile'; correlationId: string; form: FormData }  // NEW
  | { type: 'openResource'; correlationId: string; uri: string }   // NEW
  | { type: 'fetch'; correlationId: string;
      preset: string; url: string;
      method?: string; headers?: object; body?: string }           // NEW
  | { type: 'tool'; correlationId: string;
      name: string; args: object }                                 // NEW
```

### New postMessage frame types (host → sandbox)

```ts
type HostAck =
  | { type: 'message'; frame: Frame }                  // v1 (existing)
  | { type: 'history'; correlationId; frames: Frame[] }// v1 (existing)
  | { type: 'ack'; correlationId; ok; id?; error? }    // v1 (existing)
  | { type: 'uploadResult'; correlationId;
      ok; uri?; name?; size?; mime?; error? }          // NEW
  | { type: 'resourceResult'; correlationId;
      ok; url?; error? }                               // NEW
  | { type: 'fetchResult'; correlationId;
      ok; status?; headers?; body?; truncated?; error? } // NEW
  | { type: 'toolResult'; correlationId;
      ok; result?; error? }                            // NEW
```

### Host bridge changes (LoomBridge in the loom view shell)

For each new RPC type, the bridge:
1. Receives the postMessage from the iframe
2. Issues the corresponding HTTP call to `/loom/api/<ws>/<sid>/<route>`
3. Posts back the result keyed by `correlationId`

Pseudocode:
```ts
window.addEventListener('message', async (e) => {
  const msg = e.data;
  if (msg.type === 'uploadFile') {
    const resp = await fetch(`/loom/api/${ws}/${sid}/upload`, {
      method: 'POST', body: msg.form });
    const json = await resp.json();
    iframe.contentWindow.postMessage(
      { type: 'uploadResult', correlationId: msg.correlationId, ...json },
      '*');
    return;
  }
  // ... openResource, fetch, tool similarly
});
```

---

## Verifying end-to-end

Without updating the frontend SDK, you can still smoke-test the
backend with curl:

```bash
# 1. Upload a file
curl -F file=@/tmp/test.txt -F kind=document \
  http://localhost:10042/loom/api/system/demo1/upload

# 2. Use the returned URI to redirect to /files/<name>
curl -i "http://localhost:10042/loom/api/system/demo1/resource?uri=resource%3A%2F%2Fuploads%2Fsystem%2F<uuid>-test.txt"

# 3. Call the now tool
curl -H content-type:application/json -d '{"name":"now","args":{"tz":"Asia/Shanghai"}}' \
  http://localhost:10042/loom/api/system/demo1/tool

# 4. Call the echo tool
curl -H content-type:application/json -d '{"name":"echo","args":{"hello":"world"}}' \
  http://localhost:10042/loom/api/system/demo1/tool

# 5. Use the public fetch preset to GET github
curl -H content-type:application/json \
  -d '{"preset":"public","url":"https://api.github.com/repos/elixir-lang/elixir","method":"GET"}' \
  http://localhost:10042/loom/api/system/demo1/fetch
```

---

## Adding a new tool

1. Create `apps/ezagent_plugin_loom/lib/ezagent/tools/<your_tool>.ex`:

   ```elixir
   defmodule EzagentPluginLoom.Tools.Weather do
     @behaviour EzagentPluginLoom.Tool

     @impl true
     def name, do: "weather.current"

     @impl true
     def description, do: "查询指定城市当前天气"

     @impl true
     def args_schema do
       %{
         "city" => %{type: "string", required: true,
                     doc: "城市名,如 杭州 / Hangzhou"}
       }
     end

     @impl true
     def call(%{"city" => city}, _ctx) do
       # Either call EzagentPluginLoom.FetchProxy.call("weather", "https://...")
       # or your own HTTP client.
       {:ok, %{"city" => city, "temp" => 22, "condition" => "晴"}}
     end

     def call(_, _), do: {:error, :missing_city}
   end
   ```

2. Add to `config/config.exs` (or env-specific):

   ```elixir
   config :ezagent_plugin_loom, :tools, [
     EzagentPluginLoom.Tools.Echo,
     EzagentPluginLoom.Tools.Now,
     EzagentPluginLoom.Tools.Weather    # NEW
   ]
   ```

3. Restart phx.server. The AI prompt will automatically pick up the
   new tool via `ToolRegistry.prompt_block/0`.

## Adding a new fetch preset

In `config/config.exs`:

```elixir
config :ezagent_plugin_loom, :fetch_presets,
  public: %{...},                  # existing
  weather: %{                      # NEW
    url: ~r{^https://api\.openweathermap\.org/},
    methods: [:get],
    max_body: 50_000,
    timeout_ms: 5_000,
    headers: %{"appid" => {:env, "OPENWEATHER_KEY"}}
  }
```

`{:env, "OPENWEATHER_KEY"}` is resolved at request time — set the env
var in `~/restart_phx.sh` next to `DEEPSEEK_KEY`. The AI prompt's
`FetchProxy.prompt_block/0` will list this preset.

---

## Open follow-ups (deferred)

- **Per-tool rate limiting** — current implementation has no per-IP
  or per-session quotas. Easy to add (ETS counter keyed by `{tool_name,
  session_uri}`) when first abuse case appears.
- **Tool result caching** — for idempotent tools (`now` is the obvious
  one), the registry could cache (name, args) → result for N seconds.
  Not urgent.
- **Streaming fetch** — current proxy buffers full response. For
  large payloads (PDFs, video) consider streaming through SSE. Out of
  scope for v2.
- **Real identity** — `caller` in the tool ctx is currently `nil`
  (loom UI uses temp `loomui_<sid>` user). When real identity lands,
  tools can authz on the actual entity URI.

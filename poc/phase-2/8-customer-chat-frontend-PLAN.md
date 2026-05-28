# Customer Chat Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give end users a real web chat page (and an embeddable widget) for the AI customer-service flow, backed by the same session/cc/EagerBridge machinery Phase 2 already built.

**Architecture:** A public Phoenix LiveView at `/chat/:tenant` subscribes to the session events topic (read) and dispatches `chat.send` (write) — the customer mirror of the operator console. The same LiveView, rendered with `?embed=1`, is iframed by a tiny `widget.js` loader so "hosted page" and "embeddable widget" are one implementation. Reusable bootstrap logic (ensure session + cc agent + EagerBridge + join + mention synthesis) is extracted from `customer_chat_controller.ex` into a shared `CustomerChat.Bootstrap` module so the SSE controller and the LiveView share one code path (DRY). LiveView's persistent connection structurally resolves the C3 SSE-timeout tension (operator messages arrive on the same topic, no 120 s window).

**Tech Stack:** Elixir/OTP umbrella, Phoenix LiveView, Phoenix.PubSub, `Ezagent.Invocation` dispatch, `Ezagent.MessageStore`, `EzagentPluginCc.EagerBridge`, `Ezagent.Behavior.Chat` / `Ezagent.Behavior.Mode`. Code lives in `apps/ezagent_plugin_liveview` (namespace `EzagentPluginLiveview.CustomerChat.*`); routes + widget asset in `apps/ezagent_web`.

**Worktree / run context:**
- Repo: `~/workspace/ezagent42/ezagent-poc-phase-2`, branch `poc/phase-2-customer-service`.
- Compile/test: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile` — **never** run `mix deps.get` here.
- Server restart (for manual e2e), profile `poc-phase2`, port 10142 — see `MANUAL-TEST-PLAN.md` appendix (the `EZAGENT_BRIDGE_WS_URL` + `env -u …` workarounds are mandatory).

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/theme.ex` | Pure: resolve per-tenant theme map from config, with defaults | Create |
| `apps/ezagent_plugin_liveview/priv/customer_chat_themes/acme.json` | acme theme fixture | Create |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/bootstrap.ex` | Reusable session+cc+bridge+join bootstrap, message/uri builders (extracted from controller) | Create |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/components.ex` | Shared HEEx function components (bubble/list/input/banner) + row mapping | Create |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/chat_live.ex` | The public customer chat LiveView | Create |
| `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_widget_controller.ex` | Serves `widget.js` with correct content-type | Create |
| `apps/ezagent_web/lib/ezagent_web/router.ex` | Register public `live "/chat/:tenant"` + `get "/customer-chat/widget.js"` | Modify |
| `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex` | Refactor to call `CustomerChat.Bootstrap` (delete duplicated privates) | Modify |
| `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/theme_test.exs` | Theme unit tests | Create |
| `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/components_test.exs` | Row-mapping + render unit tests | Create |
| `apps/ezagent_web/test/ezagent_web/controllers/customer_chat_widget_controller_test.exs` | widget.js content-type test | Create |

**Testing note (read before starting):** `ChatLive.mount` and `Bootstrap.ensure_cc_for_conv` touch the live runtime (spawns a `claude` PTY, brings up the bridge). They are **not** unit-tested in isolation — that path is validated by the manual e2e in Task 9 against the running server, exactly as Phase 2 was accepted. Unit tests cover the pure units (theme, row mapping, uri/message builders, widget content-type) and the disconnected static render of the LiveView. Design the LiveView so the heavy bootstrap only fires on `connected?(socket)` via an async `:bootstrap` message — this keeps the dead render fast and test-safe.

---

## Task 1: Theme resolver (pure, config-driven)

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/theme.ex`
- Create: `apps/ezagent_plugin_liveview/priv/customer_chat_themes/acme.json`
- Test: `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/theme_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/theme_test.exs
defmodule EzagentPluginLiveview.CustomerChat.ThemeTest do
  use ExUnit.Case, async: true
  alias EzagentPluginLiveview.CustomerChat.Theme

  test "unknown tenant returns defaults with the tenant title interpolated" do
    t = Theme.for_tenant("no_such_tenant")
    assert t.title == "no_such_tenant"
    assert t.primary_color == "#2563eb"
    assert is_binary(t.welcome_message)
    assert is_binary(t.placeholder)
    assert t.logo_url == nil
  end

  test "acme fixture overrides defaults" do
    t = Theme.for_tenant("acme")
    assert t.title == "Acme Support"
    assert t.primary_color == "#e11d48"
    assert t.welcome_message =~ "Acme"
  end

  test "config override beats fixture file" do
    Application.put_env(:ezagent_plugin_liveview, :customer_chat_themes, %{
      "acme" => %{"title" => "Overridden", "primary_color" => "#000000"}
    })
    on_exit(fn -> Application.delete_env(:ezagent_plugin_liveview, :customer_chat_themes) end)

    t = Theme.for_tenant("acme")
    assert t.title == "Overridden"
    assert t.primary_color == "#000000"
    # unspecified keys still fall back to defaults
    assert is_binary(t.placeholder)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/theme_test.exs`
Expected: FAIL — `EzagentPluginLiveview.CustomerChat.Theme` is undefined.

- [ ] **Step 3: Write the acme fixture**

```json
// apps/ezagent_plugin_liveview/priv/customer_chat_themes/acme.json
{
  "title": "Acme Support",
  "primary_color": "#e11d48",
  "welcome_message": "Hi! I'm the Acme assistant. Ask me about warranties, orders, or returns.",
  "placeholder": "Type your message…",
  "logo_url": null
}
```

- [ ] **Step 4: Write the resolver**

```elixir
# apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/theme.ex
defmodule EzagentPluginLiveview.CustomerChat.Theme do
  @moduledoc """
  Per-tenant customer-chat theme. Config-driven — NO hardcoded tenant
  data (migration constraint #1). Resolution order (later wins):
    1. built-in defaults
    2. `priv/customer_chat_themes/<tenant>.json` fixture (if present)
    3. `config :ezagent_plugin_liveview, :customer_chat_themes` map (prod override)
  """

  @type t :: %{
          title: String.t(),
          primary_color: String.t(),
          welcome_message: String.t(),
          placeholder: String.t(),
          logo_url: String.t() | nil
        }

  @keys [:title, :primary_color, :welcome_message, :placeholder, :logo_url]

  @spec for_tenant(String.t()) :: t()
  def for_tenant(tenant) when is_binary(tenant) do
    defaults(tenant)
    |> deep_put(file_theme(tenant))
    |> deep_put(config_theme(tenant))
  end

  defp defaults(tenant) do
    %{
      title: tenant,
      primary_color: "#2563eb",
      welcome_message: "Hi! How can I help you today?",
      placeholder: "Type your message…",
      logo_url: nil
    }
  end

  defp file_theme(tenant) do
    path = Path.join(:code.priv_dir(:ezagent_plugin_liveview), "customer_chat_themes/#{tenant}.json")

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp config_theme(tenant) do
    :ezagent_plugin_liveview
    |> Application.get_env(:customer_chat_themes, %{})
    |> Map.get(tenant, %{})
  end

  # merge a string-or-atom-keyed override map onto an atom-keyed base,
  # ignoring nil values and unknown keys
  defp deep_put(base, override) when is_map(override) do
    Enum.reduce(@keys, base, fn key, acc ->
      case fetch(override, key) do
        {:ok, val} when not is_nil(val) -> Map.put(acc, key, val)
        _ -> acc
      end
    end)
  end

  defp fetch(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/theme_test.exs`
Expected: PASS (3 tests).

Note: `logo_url: null` in JSON decodes to `nil`, so `deep_put` skips it (defaults' `nil` stays). That's intended — the acme fixture has no logo.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/theme.ex \
        apps/ezagent_plugin_liveview/priv/customer_chat_themes/acme.json \
        apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/theme_test.exs
git commit -m "feat(customer-chat): config-driven per-tenant theme resolver"
```

---

## Task 2: Bootstrap module — extract reusable session+cc logic

This extracts the reusable privates from `customer_chat_controller.ex` (read it first: `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex`) into a shared module both the controller and the LiveView call. Pure builders get unit tests; the runtime-touching `ensure_cc_for_conv/3` is exercised by Task 9's e2e.

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/bootstrap.ex`
- Test: `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/bootstrap_test.exs`

- [ ] **Step 1: Write the failing test (pure builders only)**

```elixir
# apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/bootstrap_test.exs
defmodule EzagentPluginLiveview.CustomerChat.BootstrapTest do
  use ExUnit.Case, async: true
  alias EzagentPluginLiveview.CustomerChat.Bootstrap

  test "session_uri_for builds the per-conv URI" do
    uri = Bootstrap.session_uri_for("acme", "c1")
    assert URI.to_string(uri) == "session://default/acme/c1"
  end

  test "customer_uri_for builds the synthetic user URI" do
    uri = Bootstrap.customer_uri_for("acme", "alice")
    assert URI.to_string(uri) == "entity://user/acme/customer_alice"
  end

  test "agent_name_for sanitizes and truncates conv_id" do
    assert Bootstrap.agent_name_for("t2-AbC_99") == "cust_t2_AbC_99"
    long = String.duplicate("x", 80)
    assert String.length(Bootstrap.agent_name_for(long)) <= length('cust_') + 32
  end

  test "generate_conv_id is url-safe and unique-ish" do
    a = Bootstrap.generate_conv_id()
    b = Bootstrap.generate_conv_id()
    assert a =~ ~r/^[A-Za-z0-9_-]+$/
    assert a != b
  end

  test "customer_message tags mention of the cc agent" do
    cust = Bootstrap.customer_uri_for("acme", "alice")
    agent = URI.parse("entity://agent/acme/cc_cust_c1")
    msg = Bootstrap.customer_message(cust, "hello", agent)
    assert msg.mentions == [agent]
    assert msg.body.text == "hello"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/bootstrap_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the Bootstrap module**

Port the logic verbatim from the controller; only the soul-root default path changes (the controller used a path relative to its own `__ENV__.file`; here we anchor on an app-config key with the same PoC default, computed from this module's location).

```elixir
# apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/bootstrap.ex
defmodule EzagentPluginLiveview.CustomerChat.Bootstrap do
  @moduledoc """
  Shared customer-chat bootstrap, extracted from
  `EzagentWeb.CustomerChatController` so the SSE controller and the
  customer LiveView use ONE code path (DRY).

  Responsibilities:
    - URI / message builders (pure)
    - `validate_workspace/1`
    - `ensure_session/2`
    - `ensure_cc_for_conv/3` (cc agent + EagerBridge + join)
    - `dispatch_chat_send/2`

  All tenant data is parameterized — no hardcoded tenant name
  (migration constraint #1).
  """

  require Logger

  # ---- pure builders ----------------------------------------------------

  @spec session_uri_for(String.t(), String.t()) :: URI.t()
  def session_uri_for(workspace, conv_id),
    do: URI.parse("session://default/#{workspace}/#{conv_id}")

  @spec customer_uri_for(String.t(), String.t()) :: URI.t()
  def customer_uri_for(workspace, customer_id),
    do: URI.parse("entity://user/#{workspace}/customer_#{customer_id}")

  @spec agent_name_for(String.t()) :: String.t()
  def agent_name_for(conv_id), do: "cust_" <> sanitize_for_uri(conv_id)

  @spec generate_conv_id() :: String.t()
  def generate_conv_id,
    do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

  @spec customer_message(URI.t(), String.t(), URI.t()) :: Ezagent.Message.t()
  def customer_message(customer_uri, text, cc_agent_uri) do
    Ezagent.Message.new(customer_uri, %{text: text, attachments: []},
      mentions: [cc_agent_uri]
    )
  end

  defp sanitize_for_uri(conv_id) when is_binary(conv_id) do
    conv_id |> String.replace(~r/[^A-Za-z0-9]/, "_") |> String.slice(0, 32)
  end

  # ---- workspace validation --------------------------------------------

  @spec validate_workspace(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_workspace(nil), do: {:error, "workspace path segment required"}
  def validate_workspace(""), do: {:error, "workspace path segment required"}

  def validate_workspace(name) when is_binary(name) do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil -> {:error, "workspace not found"}
      _ws -> :ok
    end
  end

  # ---- session ----------------------------------------------------------

  @spec ensure_session(String.t(), String.t()) :: :ok
  def ensure_session(workspace, conv_id) do
    admin_uri = Ezagent.Entity.User.admin_uri()

    case EzagentDomainChat.create_session(conv_id, admin_uri,
           workspace_uri: URI.parse("workspace://#{workspace}"),
           template_name: "default"
         ) do
      {:ok, _session_uri, _meta} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} ->
        Logger.warning("customer_chat ensure_session(#{workspace}, #{conv_id}) failed: #{inspect(reason)}")
        :ok
    end
  end

  # ---- cc agent lifecycle ----------------------------------------------

  @spec ensure_cc_for_conv(String.t(), String.t(), URI.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def ensure_cc_for_conv(workspace, conv_id, session_uri) do
    cwd = cc_cwd_for_workspace(workspace)
    soul_path = cc_soul_path_for_workspace(workspace, "customer")
    agent_name = agent_name_for(conv_id)
    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
    ctx = %{caller: admin_uri, caps: admin_caps, reply: {:caller_inbox, self()}}

    with {:ok, agent_uri} <- ensure_cc_agent(workspace, agent_name, cwd, soul_path, ctx),
         :ok <- EzagentPluginCc.EagerBridge.ensure_bound!(agent_uri),
         :ok <- ensure_agent_in_session(session_uri, agent_uri, ctx) do
      {:ok, agent_uri}
    end
  end

  defp ensure_cc_agent(workspace, agent_name, cwd, soul_path, ctx) do
    ws_uri = URI.parse("workspace://#{workspace}")
    args = %{flavor: "cc", name: agent_name, cwd: cwd, with_pty: true}
    args = if soul_path, do: Map.put(args, :soul_path, soul_path), else: args

    case Ezagent.Workspace.create_agent(ws_uri, args, ctx) do
      {:ok, %{agent_uri: u}} -> {:ok, u}
      {:error, {:already_exists, u_str}} when is_binary(u_str) -> {:ok, URI.parse(u_str)}
      {:error, {:already_exists, %URI{} = u}} -> {:ok, u}
      {:error, reason} ->
        Logger.warning("customer_chat ensure_cc_agent(#{workspace}, #{agent_name}) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_agent_in_session(session_uri, agent_uri, ctx) do
    target = URI.new!(URI.to_string(session_uri) <> "?action=chat.join")
    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{member: agent_uri},
      ctx: %{ctx | reply: :ignore}
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("customer_chat join failed: #{inspect(reason)}")
        :ok
    end
  end

  defp cc_cwd_for_workspace(workspace) do
    root = Application.get_env(:ezagent_plugin_liveview, :customer_chat_sandbox_root, "~/poc-sandbox-phase2")
    Path.join(Path.expand(root), workspace)
  end

  defp cc_soul_path_for_workspace(workspace, role) do
    # PoC default: <repo>/poc/fixtures/plugins ; this module sits at
    # apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/bootstrap.ex
    # → six `..` hops reach the repo root.
    root_default = Path.expand("../../../../../../poc/fixtures/plugins", __ENV__.file)
    root = Application.get_env(:ezagent_plugin_liveview, :customer_chat_soul_root, root_default)
    path = Path.join([root, workspace, "souls", "#{role}.md"])
    if File.exists?(path), do: path, else: nil
  end

  # ---- dispatch ---------------------------------------------------------

  @spec dispatch_chat_send(URI.t(), Ezagent.Message.t()) :: :ok
  def dispatch_chat_send(session_uri, msg) do
    target = URI.new!(URI.to_string(session_uri) <> "?action=chat.send")
    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{caller: admin_uri, caps: admin_caps, reply: :ignore}
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok -> :ok
      other -> Logger.warning("customer_chat dispatch chat.send failed: #{inspect(other)}")
    end

    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/bootstrap_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Verify the soul-path hop count resolves correctly**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix run -e 'IO.puts(Path.expand("../../../../../../poc/fixtures/plugins", "/Users/daiming/workspace/ezagent42/ezagent-poc-phase-2/apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/bootstrap.ex"))'`
Expected output: `/Users/daiming/workspace/ezagent42/ezagent-poc-phase-2/poc/fixtures/plugins`
If the path is wrong, adjust the number of `..` segments until it matches, then re-run Step 4.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/bootstrap.ex \
        apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/bootstrap_test.exs
git commit -m "feat(customer-chat): extract shared Bootstrap (session+cc+bridge+dispatch)"
```

---

## Task 3: Point the SSE controller at the shared Bootstrap (DRY)

Refactor `customer_chat_controller.ex` to delegate to `CustomerChat.Bootstrap`, deleting its now-duplicated privates. This proves the extraction is behavior-preserving before the LiveView depends on it.

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex`
- Modify: `apps/ezagent_web/mix.exs` (add dep on `:ezagent_plugin_liveview` if not already present)

- [ ] **Step 1: Confirm the dep edge exists**

Run: `grep -n "ezagent_plugin_liveview" apps/ezagent_web/mix.exs`
Expected: a line `{:ezagent_plugin_liveview, in_umbrella: true}`. If MISSING, add it to `deps/0` in `apps/ezagent_web/mix.exs`:

```elixir
      {:ezagent_plugin_liveview, in_umbrella: true},
```

(ezagent_web references plugin LV modules by atom in the router, so this edge normally already exists. Adding the controller→Bootstrap call makes it a compile-time dep, so the edge must be real.)

- [ ] **Step 2: Replace the controller's private helpers with Bootstrap calls**

In `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex`:

Add alias near the top (after `require Logger`):

```elixir
  alias EzagentPluginLiveview.CustomerChat.Bootstrap
```

Rewrite `run_chat/5` to use Bootstrap for conv_id / URIs / ensure / dispatch (keep the SSE framing + `stream_loop` exactly as-is):

```elixir
  defp run_chat(conn, workspace, cust_id, text, params) do
    conv_id =
      case Map.get(params, "conv_id") do
        nil -> Bootstrap.generate_conv_id()
        "" -> Bootstrap.generate_conv_id()
        id when is_binary(id) -> id
      end

    customer_uri = Bootstrap.customer_uri_for(workspace, cust_id)
    session_uri = Bootstrap.session_uri_for(workspace, conv_id)
    session_uri_str = URI.to_string(session_uri)
    topic = "esr:session:#{session_uri_str}:events"

    :ok = Bootstrap.ensure_session(workspace, conv_id)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    case Bootstrap.ensure_cc_for_conv(workspace, conv_id, session_uri) do
      {:ok, cc_agent_uri} ->
        cc_agent_uri_str = URI.to_string(cc_agent_uri)
        customer_msg = Bootstrap.customer_message(customer_uri, text, cc_agent_uri)

        {:ok, conn} =
          sse_chunk(conn, "open", %{
            workspace: workspace,
            conv_id: conv_id,
            session_uri: session_uri_str,
            customer_uri: URI.to_string(customer_uri),
            agent_uri: cc_agent_uri_str,
            sent_msg_id: customer_msg.id
          })

        Bootstrap.dispatch_chat_send(session_uri, customer_msg)

        conn =
          stream_loop(conn,
            agent_uri_str: cc_agent_uri_str,
            customer_uri_str: URI.to_string(customer_uri),
            deadline: System.monotonic_time(:millisecond) + @reply_timeout_ms
          )

        Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic)
        conn

      {:error, reason} ->
        {:ok, conn} = sse_chunk(conn, "error", %{reason: "agent_setup_failed", detail: inspect(reason)})
        {:ok, conn} = sse_chunk(conn, "close", %{reason: "error"})
        Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic)
        conn
    end
  end
```

Then DELETE these now-unused privates from the controller: `validate_workspace/1` (keep — still called in `chat/2`; see note), `session_uri_for/2`, `generate_conv_id/0`, `ensure_session/2`, `dispatch_chat_send/2`, `ensure_cc_for_conv/3`, `ensure_cc_agent/5`, `ensure_agent_in_session/3`, `cc_cwd_for_workspace/1`, `cc_soul_path_for_workspace/2`, `sanitize_for_uri/1`.

**Note on `validate_workspace/1`:** it's called by `chat/2` (the public action). Replace that call site with `Bootstrap.validate_workspace(workspace)` and delete the controller's private copy. Keep `sse_chunk/2`, `stream_loop/2`, `chat/2` clauses.

- [ ] **Step 3: Compile**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | tail -20`
Expected: compiles clean. Fix any "undefined function" (a missed delegation) or "unused" (a private you forgot to delete) warnings until clean.

- [ ] **Step 4: Manual smoke (controller still works) — requires running server**

Start the server (see PLAN header / MANUAL-TEST-PLAN appendix), then:

Run:
```bash
curl -N -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"refactor","text":"How long is the warranty on my Acme laptop?","conv_id":"refactor-'$(date +%s)'"}' \
  --max-time 90
```
Expected: same 3-event SSE (`open` → `message` with 12-month/24-month Pro facts → `close`) as before the refactor.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex apps/ezagent_web/mix.exs
git commit -m "refactor(customer-chat): SSE controller delegates to shared Bootstrap"
```

---

## Task 4: Shared HEEx components + row mapping

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/components.ex`
- Test: `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/components_test.exs`

- [ ] **Step 1: Write the failing test (pure row mapping)**

```elixir
# apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/components_test.exs
defmodule EzagentPluginLiveview.CustomerChat.ComponentsTest do
  use ExUnit.Case, async: true
  alias EzagentPluginLiveview.CustomerChat.Components

  test "message_to_row classifies a customer message as :customer" do
    msg = Ezagent.Message.new(URI.parse("entity://user/acme/customer_alice"), %{text: "hi"})
    row = Components.message_to_row(msg, "entity://user/acme/customer_alice")
    assert row.kind == :customer
    assert row.text == "hi"
  end

  test "message_to_row classifies the cc agent as :agent" do
    msg = Ezagent.Message.new(URI.parse("entity://agent/acme/cc_cust_c1"), %{text: "hello"})
    row = Components.message_to_row(msg, "entity://user/acme/customer_alice")
    assert row.kind == :agent
  end

  test "message_to_row classifies a different user (operator) as :operator" do
    msg = Ezagent.Message.new(URI.parse("entity://user/acme/jane"), %{text: "I'm a human"})
    row = Components.message_to_row(msg, "entity://user/acme/customer_alice")
    assert row.kind == :operator
  end

  test "message_to_row flags the takeover notice" do
    msg = Ezagent.Message.new(URI.parse("entity://user/system/chat-router"), %{text: "(客服已接管对话)"})
    msg = %{msg | body: Map.put(msg.body, :is_takeover_notice, true)}
    row = Components.message_to_row(msg, "entity://user/acme/customer_alice")
    assert row.notice? == true
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/components_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the components module**

`kind` is from the customer's POV: `:customer` = me, `:agent` = AI, `:operator` = a human staffer, `:other` = anything else.

```elixir
# apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/components.ex
defmodule EzagentPluginLiveview.CustomerChat.Components do
  @moduledoc """
  Shared HEEx function components for the customer chat surface, plus
  the pure `message_to_row/2` mapper. Used by `CustomerChat.ChatLive`;
  reusable by the operator detail view later.
  """
  use Phoenix.Component

  @type row :: %{
          id: String.t(),
          kind: :customer | :agent | :operator | :other,
          text: String.t(),
          notice?: boolean()
        }

  @spec message_to_row(Ezagent.Message.t(), String.t()) :: row()
  def message_to_row(%Ezagent.Message{} = msg, customer_uri_str) do
    sender_str = URI.to_string(msg.sender)

    %{
      id: msg.id,
      kind: classify(sender_str, customer_uri_str),
      text: body_text(msg.body),
      notice?: takeover_notice?(msg.body)
    }
  end

  defp classify(sender, customer) when sender == customer, do: :customer

  defp classify(sender, _customer) do
    cond do
      String.starts_with?(sender, "entity://agent/") -> :agent
      String.starts_with?(sender, "entity://user/") -> :operator
      true -> :other
    end
  end

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  defp takeover_notice?(%{is_takeover_notice: true}), do: true
  defp takeover_notice?(%{"is_takeover_notice" => true}), do: true
  defp takeover_notice?(_), do: false

  # ---- components -------------------------------------------------------

  attr :row, :map, required: true

  def bubble(assigns) do
    ~H"""
    <div :if={@row.notice?} class="text-center my-3">
      <span class="inline-block text-xs px-3 py-1 rounded-full bg-amber-100 text-amber-800">
        {@row.text}
      </span>
    </div>
    <div :if={!@row.notice?} class={[
      "max-w-[80%] px-3 py-2 rounded-2xl text-sm whitespace-pre-wrap break-words mb-2",
      @row.kind == :customer && "ml-auto bg-[var(--cc-primary)] text-white",
      @row.kind == :agent && "mr-auto bg-zinc-100 text-zinc-900",
      @row.kind == :operator && "mr-auto bg-emerald-100 text-emerald-900",
      @row.kind == :other && "mr-auto bg-zinc-50 text-zinc-600"
    ]}>
      <div :if={@row.kind == :operator} class="text-[10px] text-emerald-700 mb-0.5">客服</div>
      {@row.text}
    </div>
    """
  end

  attr :messages, :list, required: true
  attr :empty?, :boolean, default: false
  attr :welcome, :string, required: true

  def message_list(assigns) do
    ~H"""
    <div id="cc-messages" phx-update="stream" class="flex flex-col">
      <div :if={@empty?} id="cc-welcome" class="mr-auto max-w-[80%] px-3 py-2 rounded-2xl text-sm bg-zinc-100 text-zinc-900 mb-2">
        {@welcome}
      </div>
      <div :for={{dom_id, row} <- @messages} id={dom_id}>
        <.bubble row={row} />
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :placeholder, :string, required: true

  def composer(assigns) do
    ~H"""
    <.form for={@form} phx-submit="send" class="flex gap-2 p-3 border-t border-zinc-200 bg-white">
      <input
        type="text"
        name="chat[text]"
        id="cc-input"
        autocomplete="off"
        placeholder={@placeholder}
        class="flex-1 px-3 py-2 text-sm border border-zinc-300 rounded-full focus:outline-none focus:ring-2 focus:ring-[var(--cc-primary)]"
      />
      <button type="submit" class="px-4 py-2 text-sm rounded-full text-white bg-[var(--cc-primary)]">
        Send
      </button>
    </.form>
    """
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/components_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/components.ex \
        apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/components_test.exs
git commit -m "feat(customer-chat): shared HEEx components + message row mapping"
```

---

## Task 5: CustomerChat.ChatLive — mount, async bootstrap, render

The customer-side mirror of `CustomerSessionViewLive`. Heavy bootstrap runs only on `connected?` via a self-sent `:bootstrap` message, so the dead render is instant and test-safe.

**Files:**
- Create: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/chat_live.ex`

- [ ] **Step 1: Write the LiveView**

```elixir
# apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/chat_live.ex
defmodule EzagentPluginLiveview.CustomerChat.ChatLive do
  @moduledoc """
  Public customer chat page at `/chat/:tenant`. No login. The customer
  is a synthetic `entity://user/<tenant>/customer_<id>`.

  Read path: subscribe to the session events topic.
  Write path: dispatch `chat.send` via Bootstrap (mention-synthesized
  to the cc agent). Operator takeover messages + the takeover notice
  arrive on the SAME topic (no SSE 120 s window — this is the C3-tension
  fix).

  Heavy bootstrap (cc spawn + EagerBridge) runs only after `connected?`
  via a self-sent `:bootstrap` message, so the dead render is instant.
  """
  use Phoenix.LiveView
  import EzagentPluginLiveview.CustomerChat.Components
  alias EzagentPluginLiveview.CustomerChat.{Bootstrap, Components, Theme}
  require Logger

  @message_limit 50

  @impl true
  def mount(%{"tenant" => tenant} = params, _session, socket) do
    embed? = Map.get(params, "embed") == "1"
    customer_id = Map.get(params, "cid") || rand_customer_id()
    conv_id = Map.get(params, "conv") || Bootstrap.generate_conv_id()

    session_uri = Bootstrap.session_uri_for(tenant, conv_id)
    session_uri_str = URI.to_string(session_uri)
    customer_uri = Bootstrap.customer_uri_for(tenant, customer_id)

    socket =
      socket
      |> assign(:tenant, tenant)
      |> assign(:embed?, embed?)
      |> assign(:theme, Theme.for_tenant(tenant))
      |> assign(:customer_id, customer_id)
      |> assign(:conv_id, conv_id)
      |> assign(:session_uri, session_uri)
      |> assign(:session_uri_str, session_uri_str)
      |> assign(:customer_uri_str, URI.to_string(customer_uri))
      |> assign(:mode, :auto)
      |> assign(:status, :connecting)
      |> assign(:error, nil)
      |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))
      |> assign(:page_title, Theme.for_tenant(tenant).title)

    if connected?(socket) do
      topic = Ezagent.Behavior.Chat.session_events_topic(session_uri)
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
      send(self(), :bootstrap)

      history = load_history(session_uri, URI.to_string(customer_uri))
      mode = lookup_mode(session_uri)

      {:ok,
       socket
       |> assign(:mode, mode)
       |> stream(:messages, history)
       |> assign(:messages_empty?, history == [])}
    else
      {:ok,
       socket
       |> stream(:messages, [])
       |> assign(:messages_empty?, true)}
    end
  end

  @impl true
  def handle_info(:bootstrap, socket) do
    %{tenant: tenant, conv_id: conv_id, session_uri: session_uri} = socket.assigns
    :ok = Bootstrap.ensure_session(tenant, conv_id)

    case Bootstrap.ensure_cc_for_conv(tenant, conv_id, session_uri) do
      {:ok, agent_uri} ->
        {:noreply,
         socket
         |> assign(:status, :ready)
         |> assign(:cc_agent_uri, agent_uri)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> assign(:error, "Could not reach the assistant. Please try again.")
         |> tap(fn _ -> Logger.warning("ChatLive bootstrap failed: #{inspect(reason)}") end)}
    end
  end

  def handle_info({:chat_message, src, %Ezagent.Message{} = msg}, socket) do
    if URI.to_string(src) == socket.assigns.session_uri_str do
      row = Components.message_to_row(msg, socket.assigns.customer_uri_str)
      mode = if row.notice?, do: :takeover, else: socket.assigns.mode

      {:noreply,
       socket
       |> assign(:messages_empty?, false)
       |> assign(:mode, mode)
       |> stream_insert(:messages, row, at: -1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("send", %{"chat" => %{"text" => text}}, socket)
      when is_binary(text) and text != "" do
    case socket.assigns do
      %{status: :ready, cc_agent_uri: agent_uri} ->
        customer_uri = URI.parse(socket.assigns.customer_uri_str)
        msg = Bootstrap.customer_message(customer_uri, String.trim(text), agent_uri)
        Bootstrap.dispatch_chat_send(socket.assigns.session_uri, msg)

        # optimistically echo my own message (broadcast also delivers it,
        # but stream dedups by dom id from msg.id)
        row = Components.message_to_row(msg, socket.assigns.customer_uri_str)

        {:noreply,
         socket
         |> assign(:messages_empty?, false)
         |> stream_insert(:messages, row, at: -1)
         |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))}

      _not_ready ->
        {:noreply, socket}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class={["flex flex-col", @embed? && "h-screen bg-transparent" || "h-screen max-w-lg mx-auto border-x border-zinc-200"]}
      style={"--cc-primary: #{@theme.primary_color};"}
    >
      <header :if={!@embed?} class="flex items-center gap-2 px-4 py-3 border-b border-zinc-200 bg-white">
        <img :if={@theme.logo_url} src={@theme.logo_url} class="h-6 w-6 rounded" />
        <span class="font-semibold text-zinc-900">{@theme.title}</span>
        <span :if={@mode == :takeover} class="ml-auto text-xs px-2 py-0.5 rounded-full bg-amber-100 text-amber-800">
          客服已接管
        </span>
      </header>

      <div class="flex-1 overflow-y-auto px-4 py-3 bg-zinc-50">
        <.message_list messages={@streams.messages} empty?={@messages_empty?} welcome={@theme.welcome_message} />
        <p :if={@status == :connecting} class="text-center text-xs text-zinc-400 mt-2">connecting…</p>
        <p :if={@status == :error} class="text-center text-xs text-rose-500 mt-2">{@error}</p>
      </div>

      <.composer form={@compose_form} placeholder={@theme.placeholder} />
    </div>
    """
  end

  # ---- helpers ----------------------------------------------------------

  defp load_history(session_uri, customer_uri_str) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@message_limit)
    |> Enum.reverse()
    |> Enum.map(&Components.message_to_row(&1, customer_uri_str))
  end

  defp lookup_mode(session_uri) do
    target = URI.new!(URI.to_string(session_uri) <> "?action=mode.get")
    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{},
      ctx: %{caller: admin_uri, caps: admin_caps, reply: {:caller_inbox, self()}}
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, %{mode: mode}} -> mode
      _ -> :auto
    end
  end

  defp rand_customer_id do
    "anon_" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
  end
end
```

- [ ] **Step 2: Compile**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | tail -20`
Expected: clean compile. Common fixes: `to_form` requires `Phoenix.Component` (imported via `use Phoenix.LiveView`); if `~H` flags a missing import for `.message_list`/`.composer`, confirm the `import EzagentPluginLiveview.CustomerChat.Components` line is present.

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/chat_live.ex
git commit -m "feat(customer-chat): public ChatLive (async cc bootstrap, themed render)"
```

---

## Task 6: Register the public route

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

- [ ] **Step 1: Read the existing public scope**

Run: `grep -n 'scope \"/\"\|live_session :public\|HomeLive\|put_locale' apps/ezagent_web/lib/ezagent_web/router.ex`
Confirm the public scope shape: `scope "/", EzagentWeb do ... pipe_through :browser ... live_session :public, on_mount: {EzagentWeb.LiveAuth, :put_locale} do live "/", HomeLive end end`.

- [ ] **Step 2: Add a public scope for the customer chat LV**

Add this block AFTER the existing `scope "/", EzagentWeb` public block (a separate scope aliased to the plugin so the module resolves cleanly):

```elixir
  # Public customer chat page (Phase 3). No login — the customer is a
  # synthetic entity://user/<tenant>/customer_<id>. Reuses the :public
  # on_mount (locale only, no auth). Same LV serves the hosted page and
  # the iframe widget (?embed=1).
  scope "/", EzagentPluginLiveview do
    pipe_through :browser

    live_session :customer_chat_public, on_mount: {EzagentWeb.LiveAuth, :put_locale} do
      live "/chat/:tenant", CustomerChat.ChatLive
    end
  end
```

- [ ] **Step 3: Compile**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | tail -20`
Expected: clean. If "module EzagentPluginLiveview.CustomerChat.ChatLive is not available", confirm Task 5 compiled and the dep edge from Task 3 Step 1 exists.

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_web/lib/ezagent_web/router.ex
git commit -m "feat(customer-chat): register public /chat/:tenant route"
```

---

## Task 7: widget.js loader + route

**Files:**
- Create: `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_widget_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Test: `apps/ezagent_web/test/ezagent_web/controllers/customer_chat_widget_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/ezagent_web/test/ezagent_web/controllers/customer_chat_widget_controller_test.exs
defmodule EzagentWeb.CustomerChatWidgetControllerTest do
  use EzagentWeb.ConnCase, async: true

  test "GET /customer-chat/widget.js serves javascript", %{conn: conn} do
    conn = get(conn, "/customer-chat/widget.js")
    assert response_content_type(conn, :js) =~ "javascript"
    body = response(conn, 200)
    assert body =~ "data-tenant"
    assert body =~ "/chat/"
    assert body =~ "iframe"
  end
end
```

(If `EzagentWeb.ConnCase` doesn't exist, mirror whatever case template the other controller tests in `apps/ezagent_web/test` use — check with `ls apps/ezagent_web/test/support`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_web/test/ezagent_web/controllers/customer_chat_widget_controller_test.exs`
Expected: FAIL — no route / controller.

- [ ] **Step 3: Write the controller**

The JS is a module attribute (no static-asset plumbing). It reads `data-tenant` + optional `data-base-url`/`data-primary`, injects a launcher bubble, and toggles an iframe to `/chat/<tenant>?embed=1`.

```elixir
# apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_widget_controller.ex
defmodule EzagentWeb.CustomerChatWidgetController do
  @moduledoc """
  Serves the embeddable customer-chat widget loader as javascript.
  A business embeds:

      <script src="https://<host>/customer-chat/widget.js" data-tenant="acme"></script>

  The loader injects a floating launcher button; clicking it toggles an
  iframe pointing at `/chat/<tenant>?embed=1` (same LiveView as the
  hosted page). Style isolation comes from the iframe boundary.
  """
  use Phoenix.Controller, formats: [:json]

  @widget_js """
  (function () {
    var s = document.currentScript;
    var tenant = s.getAttribute('data-tenant');
    if (!tenant) { console.error('[ezagent-chat] missing data-tenant'); return; }
    var base = s.getAttribute('data-base-url') || (new URL(s.src)).origin;
    var primary = s.getAttribute('data-primary') || '#2563eb';

    var btn = document.createElement('button');
    btn.setAttribute('aria-label', 'Chat');
    btn.style.cssText = 'position:fixed;right:20px;bottom:20px;width:56px;height:56px;border:none;border-radius:50%;cursor:pointer;z-index:2147483646;box-shadow:0 4px 12px rgba(0,0,0,.2);background:' + primary + ';color:#fff;font-size:24px;';
    btn.textContent = '\\uD83D\\uDCAC';

    var frame = document.createElement('iframe');
    frame.src = base + '/chat/' + encodeURIComponent(tenant) + '?embed=1';
    frame.style.cssText = 'position:fixed;right:20px;bottom:88px;width:380px;height:560px;max-width:calc(100vw - 40px);max-height:calc(100vh - 120px);border:none;border-radius:12px;box-shadow:0 8px 30px rgba(0,0,0,.25);z-index:2147483647;display:none;background:#fff;';

    var open = false;
    btn.addEventListener('click', function () {
      open = !open;
      frame.style.display = open ? 'block' : 'none';
    });

    document.body.appendChild(frame);
    document.body.appendChild(btn);
  })();
  """

  def widget(conn, _params) do
    conn
    |> put_resp_content_type("application/javascript")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, @widget_js)
  end
end
```

- [ ] **Step 4: Add the route**

In `apps/ezagent_web/lib/ezagent_web/router.ex`, inside the public `scope "/", EzagentWeb do ... pipe_through :browser` block (next to `HomeLive`), add:

```elixir
    get "/customer-chat/widget.js", CustomerChatWidgetController, :widget
```

- [ ] **Step 5: Run test to verify it passes**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_web/test/ezagent_web/controllers/customer_chat_widget_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_widget_controller.ex \
        apps/ezagent_web/lib/ezagent_web/router.ex \
        apps/ezagent_web/test/ezagent_web/controllers/customer_chat_widget_controller_test.exs
git commit -m "feat(customer-chat): serve embeddable widget.js loader"
```

---

## Task 8: conv_id resume via localStorage (JS hook)

So a page reload keeps the same conversation. A tiny LiveView JS hook persists `conv_id`/`cid` to localStorage and, on first load without a `?conv=`, redirects to the canonical URL carrying them.

**Files:**
- Modify: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/chat_live.ex` (push the canonical params to the client; accept them back)
- Modify: wherever `ezagent_web` registers LiveView JS hooks (find with grep below)

- [ ] **Step 1: Find the app.js hook registration point**

Run: `grep -rn "new LiveSocket\|hooks:\|Hooks" apps/ezagent_web/assets/js/ | head`
Expected: an `app.js` constructing `new LiveSocket(..., { hooks: Hooks })`. Note the file path and the `Hooks` object.

- [ ] **Step 2: Add a `CustomerChatPersist` hook**

In the `app.js` hooks object (mirror the existing hook style in that file), add:

```javascript
Hooks.CustomerChatPersist = {
  mounted() {
    const tenant = this.el.dataset.tenant;
    const key = "ezagent_cc_conv_" + tenant;
    const url = new URL(window.location.href);

    if (!url.searchParams.get("conv")) {
      const saved = localStorage.getItem(key);
      if (saved) {
        const [conv, cid] = saved.split("|");
        url.searchParams.set("conv", conv);
        if (cid) url.searchParams.set("cid", cid);
        window.location.replace(url.toString()); // reload with restored ids
        return;
      }
    }
    // persist whatever the server resolved (pushed via data attrs)
    const conv = this.el.dataset.conv;
    const cid = this.el.dataset.cid;
    if (conv) localStorage.setItem(key, conv + "|" + (cid || ""));
  }
};
```

- [ ] **Step 3: Attach the hook in ChatLive render**

In `chat_live.ex`, add `phx-hook` + data attrs to the root `<div>` (only when NOT embed, so the iframe's own URL is the source of truth there — for embed we still persist so reopening the bubble resumes):

Change the root div opening tag to include:

```elixir
      id="cc-root"
      phx-hook="CustomerChatPersist"
      data-tenant={@tenant}
      data-conv={@conv_id}
      data-cid={@customer_id}
```

(Add these attributes to the existing root `<div>` in `render/1`; keep the `class`/`style` already there.)

- [ ] **Step 4: Compile + rebuild assets**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | tail -5`
Then if the project uses an esbuild step: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix assets.build 2>&1 | tail -5` (skip if no such alias — `mix phx.server` builds on boot in dev).
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/chat_live.ex apps/ezagent_web/assets/
git commit -m "feat(customer-chat): persist+resume conv_id via localStorage hook"
```

---

## Task 9: End-to-end manual validation (acceptance gate)

This is the real integration gate for the runtime-coupled path (mirrors how Phase 2 was accepted). Restart the server first (PLAN header / MANUAL-TEST-PLAN appendix).

- [ ] **Step 1: Hosted page — basic + soul personalization**

Open `http://localhost:10142/chat/acme` in a browser. Send: `How long is the warranty on my Acme laptop?`
Expected: themed page (title "Acme Support", rose send button); within ~10 s the AI reply streams in with **12-month** (standard) and **24-month / Pro line** facts. Acceptance criterion #1.

- [ ] **Step 2: Reload resume**

Reload the page. Expected: the same conversation (your message + the AI reply) is restored — not a blank thread. Acceptance criterion #4.

- [ ] **Step 3: Widget embed**

Create `/tmp/widget-test.html`:
```html
<!doctype html><html><body><h1>Business site</h1>
<script src="http://localhost:10142/customer-chat/widget.js" data-tenant="acme"></script>
</body></html>
```
Open it (`file:///tmp/widget-test.html`). Expect a chat bubble bottom-right; click → iframe chat panel; send a message → AI replies inside the bubble. Acceptance criterion #2.

> If the iframe is blank due to a frame-ancestors / CSP or `X-Frame-Options` header on the LiveView response, note it in FINDINGS and relax it for the `/chat/:tenant` route only (prototype). Capture the exact header to change; do not globally disable framing.

- [ ] **Step 4: Operator takeover — live, no timeout**

Keep the hosted `/chat/acme` page open. In a second browser session, log in as admin (`entity://user/system/admin` / `ezagent-dev`), go to `/admin/customer_sessions`, open the matching session, click **Take over**, then send `Hi, this is a human agent.`
Expected on the customer page (live, no reload): the `客服已接管` banner appears, the takeover notice bubble shows, and the operator's message arrives — all within the persistent LiveView connection, no SSE timeout. Acceptance criterion #3 (the C3-tension fix).

- [ ] **Step 5: No hardcoded tenant data**

Run:
```bash
grep -rniE '"acme"|acme' apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/ apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_widget_controller.ex
```
Expected: zero matches in code (the only `acme` lives in `priv/customer_chat_themes/acme.json` and `poc/fixtures`, which are fixtures, not code). Acceptance criterion #5.

- [ ] **Step 6: Record results + commit FINDINGS**

Append a "Phase 3 frontend — acceptance results" section to `poc/phase-2/ACCEPTANCE.md` capturing the 5 criteria (pass/fail + any header tweak from Step 3).

```bash
git add poc/phase-2/ACCEPTANCE.md
git commit -m "docs(customer-chat): record Phase 3 frontend acceptance results"
```

---

## Task 10: Full suite + compile-clean checkpoint

- [ ] **Step 1: Run the customer-chat unit tests together**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/ apps/ezagent_web/test/ezagent_web/controllers/customer_chat_widget_controller_test.exs`
Expected: all green.

- [ ] **Step 2: Compile with warnings-as-errors to catch drift**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile --warnings-as-errors 2>&1 | tail -20`
Expected: clean (fix any unused-alias / unused-private warnings left over from the Task 3 controller refactor).

- [ ] **Step 3: Final commit if anything changed**

```bash
git add -A
git commit -m "chore(customer-chat): compile-clean + green unit suite checkpoint"
```

---

## Self-Review (completed during plan authoring)

**Spec coverage:** §3 components → Tasks 1,2,4,5,7 (+ controller DRY in Task 3); §4 LiveView/C3 fix → Task 5 + Task 9 Step 4; §5 ChatLive → Task 5; §6 components → Task 4; §7 widget → Task 7; §8 theme → Task 1; §9 operator continuity → unchanged (validated Task 9 Step 4); §11 conv_id resume → Task 8; §13 acceptance → Task 9. No gaps.

**Type consistency:** `Bootstrap.customer_message/3`, `session_uri_for/2`, `customer_uri_for/2`, `agent_name_for/1`, `generate_conv_id/0`, `ensure_session/2`, `ensure_cc_for_conv/3`, `dispatch_chat_send/2` — names identical across Tasks 2, 3, 5. `Components.message_to_row/2` returns `%{id, kind, text, notice?}` — consumed with those exact keys in `ChatLive` and `bubble/1`. `Theme.for_tenant/1` returns `%{title, primary_color, welcome_message, placeholder, logo_url}` — consumed with those keys in `ChatLive.render`.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; runtime-coupled validation is explicitly delegated to Task 9 manual e2e (not hidden behind "write tests for the above").

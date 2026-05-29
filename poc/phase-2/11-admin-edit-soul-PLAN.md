# Editable Soul (Scope #1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin edit a tenant's customer-service soul in a UI so that new
conversations automatically use the edited soul (with reset-to-default and
single-step revert).

**Architecture:** A plugin-local `SoulStore` owns soul-path resolution
(sandbox-first, fixture-fallback) and edited-file I/O; `bootstrap.ex`'s existing
spawn path delegates to it so editor and spawn agree. A `ConfigLive` LiveView at
`/plugins/customer-chat/:tenant/config` edits the soul body; `ConfigAuth` gates it
on the workspace-admin capability (admin passes via its all-`:any` cap through the
standard matcher — no membership bypass). Everything new lives in the
`ezagent_plugin_customer_chat` app; **zero core changes**.

**Tech Stack:** Elixir / Phoenix LiveView (HEEX `~H`), ExUnit, ezagent capability
model (`Ezagent.Capability.matches?/2`, `Ezagent.Identity.list_caps_for/1`).

**Spec:** `poc/phase-2/11-admin-edit-soul-design.md` (read it first).

---

## Environment / run rules (READ FIRST — iron rules)

- **Every `mix` command is prefixed** with the shared deps path, and you **NEVER
  run `mix deps.get`** (it corrupts the shared cache):
  ```bash
  DEPS=/Users/daiming/workspace/ezagent42/.poc-shared-deps
  # then, always:  MIX_DEPS_PATH=$DEPS mix <cmd>
  ```
- **Run this app's tests:**
  ```bash
  cd /Users/daiming/workspace/ezagent42/ezagent
  MIX_DEPS_PATH=$DEPS mix test apps/ezagent_plugin_customer_chat
  ```
  A single file: append the path, e.g.
  `... mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs`.
- **Compile with warnings-as-errors** (our-code-clean gate):
  `MIX_DEPS_PATH=$DEPS mix compile --warning-as-errors`.
- Work happens directly on branch `poc/phase-2-customer-service`. Commit per task.
- Running the server / browser e2e (Task 8) needs the full profile up on port
  10142 — see `poc/phase-2/HANDOFF-2026-05-30.md` "Running server" + the asset
  gotcha. Tasks 1–3 (the TDD core) need only the toolchain, no server.

## Testing posture (matches the existing plugin)

The plugin's existing tests are **pure unit tests** (`bootstrap_test.exs`,
`theme_test.exs`); there are **no LiveView integration tests** (LiveView auth
on_mount needs a logged-in conn + real caps). We follow the same posture:
**TDD the pure modules** (`SoulStore`, `ConfigAuth`), and **verify the wired
LiveView/route/link via compile + the browser e2e** (Task 8), exactly as the
prior frontend + extraction work was accepted.

---

## File structure

| Action | Path | Responsibility |
|---|---|---|
| Create | `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/soul_store.ex` | Resolution rule + edited/prev/fixture file I/O |
| Create | `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs` | Unit tests for SoulStore |
| Create | `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_auth.ex` | Workspace-admin capability gate (Option E) |
| Create | `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/config_auth_test.exs` | Unit tests for ConfigAuth |
| Create | `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_live.ex` | The edit UI (textarea + save/revert/reset) |
| Modify | `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex` | Delegate `cc_soul_path_for_workspace/2` → SoulStore |
| Modify | `apps/ezagent_web/lib/ezagent_web/router.ex` | Add the ConfigLive route (in the **EzagentPluginCustomerChat** scope) |
| Modify | `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex` | Gated "Configure" link |
| Create | `poc/fixtures/plugins/cinnox/souls/customer.md` | Seed cinnox soul (from AutoService) |

---

## Task 1: `SoulStore` — resolution + file I/O (TDD)

**Files:**
- Create: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/soul_store.ex`
- Test: `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs`:

```elixir
defmodule EzagentPluginCustomerChat.SoulStoreTest do
  # async: false — mutates global Application env (the two soul roots).
  use ExUnit.Case, async: false
  alias EzagentPluginCustomerChat.SoulStore

  setup do
    base = Path.join(System.tmp_dir!(), "soulstore_#{System.unique_integer([:positive])}")
    sandbox = Path.join(base, "sandbox")
    fixtures = Path.join(base, "fixtures")
    File.mkdir_p!(sandbox)
    File.mkdir_p!(fixtures)
    Application.put_env(:ezagent_plugin_customer_chat, :customer_chat_sandbox_root, sandbox)
    Application.put_env(:ezagent_plugin_customer_chat, :customer_chat_soul_root, fixtures)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_customer_chat, :customer_chat_sandbox_root)
      Application.delete_env(:ezagent_plugin_customer_chat, :customer_chat_soul_root)
      File.rm_rf!(base)
    end)

    %{fixtures: fixtures}
  end

  defp write_fixture(fixtures, tenant, body) do
    p = Path.join([fixtures, tenant, "souls", "customer.md"])
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, body)
  end

  test "effective_path falls back to fixture when no edited file", %{fixtures: f} do
    write_fixture(f, "acme", "FIXTURE")
    assert SoulStore.effective_path("acme", "customer") == SoulStore.fixture_path("acme", "customer")
    assert {:ok, "FIXTURE", :fixture} = SoulStore.read_effective("acme", "customer")
  end

  test "effective_path prefers the edited file", %{fixtures: f} do
    write_fixture(f, "acme", "FIXTURE")
    :ok = SoulStore.write("acme", "customer", "EDITED")
    assert SoulStore.effective_path("acme", "customer") == SoulStore.edited_path("acme", "customer")
    assert {:ok, "EDITED", :edited} = SoulStore.read_effective("acme", "customer")
  end

  test "effective_path is nil when neither edited nor fixture exists" do
    assert SoulStore.effective_path("ghost", "customer") == nil
    assert {:ok, "", :none} = SoulStore.read_effective("ghost", "customer")
  end

  test "write snapshots the prior edited file; revert_previous restores it", %{fixtures: f} do
    write_fixture(f, "acme", "FIXTURE")
    :ok = SoulStore.write("acme", "customer", "V1")
    refute SoulStore.has_previous?("acme", "customer")
    :ok = SoulStore.write("acme", "customer", "V2")
    assert SoulStore.has_previous?("acme", "customer")
    assert {:ok, "V2", :edited} = SoulStore.read_effective("acme", "customer")
    assert :ok = SoulStore.revert_previous("acme", "customer")
    assert {:ok, "V1", :edited} = SoulStore.read_effective("acme", "customer")
  end

  test "revert_previous errors with no snapshot" do
    assert {:error, :no_previous} = SoulStore.revert_previous("acme", "customer")
  end

  test "reset deletes edited + prev, falling back to fixture", %{fixtures: f} do
    write_fixture(f, "acme", "FIXTURE")
    :ok = SoulStore.write("acme", "customer", "V1")
    :ok = SoulStore.write("acme", "customer", "V2")
    assert :ok = SoulStore.reset("acme", "customer")
    refute SoulStore.edited?("acme", "customer")
    refute SoulStore.has_previous?("acme", "customer")
    assert {:ok, "FIXTURE", :fixture} = SoulStore.read_effective("acme", "customer")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent
MIX_DEPS_PATH=$DEPS mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs
```
Expected: FAIL — `EzagentPluginCustomerChat.SoulStore` is undefined.

- [ ] **Step 3: Write the implementation**

Create `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/soul_store.ex`:

```elixir
defmodule EzagentPluginCustomerChat.SoulStore do
  @moduledoc """
  Single source of truth for customer-soul resolution and edited-file I/O.

  Resolution (used by BOTH the editor and the cc spawn path): edited file →
  fixture (immutable seed) → nil. The editor writes ONLY the soul body; the
  channel preamble is prepended by `cc_agent` at spawn (see design §4).

  Layout (role = "customer"):
    <sandbox_root>/<tenant>/souls/<role>.md        edited   (writable override)
    <sandbox_root>/<tenant>/souls/<role>.prev.md   prev     (single-step undo)
    <soul_root>/<tenant>/souls/<role>.md           fixture  (immutable seed)
  """

  @sandbox_default "~/poc-sandbox-phase2"

  @spec effective_path(String.t(), String.t()) :: Path.t() | nil
  def effective_path(tenant, role) do
    ep = edited_path(tenant, role)
    if File.exists?(ep), do: ep, else: fixture_path(tenant, role)
  end

  @spec edited_path(String.t(), String.t()) :: Path.t()
  def edited_path(tenant, role), do: Path.join([sandbox_root(), tenant, "souls", "#{role}.md"])

  @spec prev_path(String.t(), String.t()) :: Path.t()
  def prev_path(tenant, role), do: Path.join([sandbox_root(), tenant, "souls", "#{role}.prev.md"])

  @spec fixture_path(String.t(), String.t()) :: Path.t() | nil
  def fixture_path(tenant, role) do
    path = Path.join([soul_root(), tenant, "souls", "#{role}.md"])
    if File.exists?(path), do: path, else: nil
  end

  @spec read_effective(String.t(), String.t()) :: {:ok, String.t(), :edited | :fixture | :none}
  def read_effective(tenant, role) do
    case effective_path(tenant, role) do
      nil ->
        {:ok, "", :none}

      path ->
        source = if path == edited_path(tenant, role), do: :edited, else: :fixture

        case File.read(path) do
          {:ok, body} -> {:ok, body, source}
          {:error, _} -> {:ok, "", :none}
        end
    end
  end

  @spec write(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write(tenant, role, body) do
    ep = edited_path(tenant, role)
    File.mkdir_p!(Path.dirname(ep))
    if File.exists?(ep), do: File.cp!(ep, prev_path(tenant, role))
    File.write(ep, body)
  end

  @spec revert_previous(String.t(), String.t()) :: :ok | {:error, :no_previous}
  def revert_previous(tenant, role) do
    pp = prev_path(tenant, role)

    if File.exists?(pp) do
      File.cp!(pp, edited_path(tenant, role))
      :ok
    else
      {:error, :no_previous}
    end
  end

  @spec reset(String.t(), String.t()) :: :ok
  def reset(tenant, role) do
    File.rm(edited_path(tenant, role))
    File.rm(prev_path(tenant, role))
    :ok
  end

  @spec edited?(String.t(), String.t()) :: boolean()
  def edited?(tenant, role), do: File.exists?(edited_path(tenant, role))

  @spec has_previous?(String.t(), String.t()) :: boolean()
  def has_previous?(tenant, role), do: File.exists?(prev_path(tenant, role))

  defp sandbox_root do
    Path.expand(
      Application.get_env(:ezagent_plugin_customer_chat, :customer_chat_sandbox_root, @sandbox_default)
    )
  end

  defp soul_root do
    # This module sits beside bootstrap.ex at
    # apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/soul_store.ex
    # → five `..` from __ENV__.file (file-as-dir) reach the repo root, matching the
    # path bootstrap.ex used before this refactor.
    root_default = Path.expand("../../../../../poc/fixtures/plugins", __ENV__.file)
    Application.get_env(:ezagent_plugin_customer_chat, :customer_chat_soul_root, root_default)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
MIX_DEPS_PATH=$DEPS mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs
```
Expected: PASS (6 tests).

- [ ] **Step 5: Format + warnings-as-errors**

```bash
MIX_DEPS_PATH=$DEPS mix format apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/soul_store.ex apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs
MIX_DEPS_PATH=$DEPS mix compile --warning-as-errors
```
Expected: no warnings.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/soul_store.ex \
        apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs
git commit -m "feat(customer-chat): SoulStore — sandbox-first soul resolution + edited/prev/fixture I/O"
```

---

## Task 2: Delegate `bootstrap.ex` resolution to `SoulStore`

Make the cc spawn path use the same resolution rule as the editor.

**Files:**
- Modify: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex:149-158`

- [ ] **Step 1: Replace the private resolver with a delegate**

In `bootstrap.ex`, replace the whole `cc_soul_path_for_workspace/2` function
(currently lines 149-158, fixture-only) with:

```elixir
  defp cc_soul_path_for_workspace(workspace, role) do
    EzagentPluginCustomerChat.SoulStore.effective_path(workspace, role)
  end
```

(Leave the call site at line 98 — `soul_path = cc_soul_path_for_workspace(workspace, "customer")` — unchanged.)

- [ ] **Step 2: Compile (warnings-as-errors)**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent
MIX_DEPS_PATH=$DEPS mix compile --warning-as-errors
```
Expected: clean. (If it warns the old `root_default`/`File.exists?` lines are now
unused, you removed them correctly — there should be nothing left to warn about.)

- [ ] **Step 3: Run the plugin's existing tests (no regression)**

```bash
MIX_DEPS_PATH=$DEPS mix test apps/ezagent_plugin_customer_chat
```
Expected: PASS (existing bootstrap/theme/components tests + Task 1's SoulStore tests).
The take-effect behavior (a new conversation reads the edited soul) is proven in
the browser e2e (Task 8), since it requires a real cc spawn.

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex
git commit -m "refactor(customer-chat): bootstrap soul-path delegates to SoulStore (one resolution rule)"
```

---

## Task 3: `ConfigAuth` — workspace-admin capability gate (TDD)

**Files:**
- Create: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_auth.ex`
- Test: `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/config_auth_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/config_auth_test.exs`:

```elixir
defmodule EzagentPluginCustomerChat.ConfigAuthTest do
  use ExUnit.Case, async: true
  alias EzagentPluginCustomerChat.ConfigAuth
  alias Ezagent.Capability

  test "bootstrap admin all-:any cap admits any tenant" do
    caps = [Capability.cap(:any, :any, :any)]
    assert ConfigAuth.caps_admit?(caps, "cinnox")
    assert ConfigAuth.caps_admit?(caps, "acme")
  end

  test "cross-workspace workspace-admin cap admits" do
    caps = [Capability.cap(:workspace, Ezagent.Behavior.Workspace, :any)]
    assert ConfigAuth.caps_admit?(caps, "cinnox")
  end

  test "tenant-scoped workspace-admin cap admits only its own tenant" do
    caps = [
      Capability.cap(:workspace, Ezagent.Behavior.Workspace, :any, :any, URI.parse("workspace://cinnox"))
    ]

    assert ConfigAuth.caps_admit?(caps, "cinnox")
    refute ConfigAuth.caps_admit?(caps, "acme")
  end

  test "responder Mode.set cap does NOT admit" do
    caps = [
      Capability.cap(:session, Ezagent.Behavior.Mode, :set, :any, URI.parse("workspace://cinnox"))
    ]

    refute ConfigAuth.caps_admit?(caps, "cinnox")
  end

  test "no caps does not admit" do
    refute ConfigAuth.caps_admit?([], "cinnox")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
MIX_DEPS_PATH=$DEPS mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/config_auth_test.exs
```
Expected: FAIL — `EzagentPluginCustomerChat.ConfigAuth` is undefined.

- [ ] **Step 3: Write the implementation**

Create `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_auth.ex`:

```elixir
defmodule EzagentPluginCustomerChat.ConfigAuth do
  @moduledoc """
  Authorization for editing a tenant's customer-chat configuration (the soul).

  Option E (design §5.5): "whoever administers tenant X may configure tenant X's
  plugins." Gated on the workspace-admin capability via the standard matcher, so
  the bootstrap admin passes through its stored all-`:any` cap — NOT via an
  `is_system_member?` membership bypass. Operators/responders (who hold only
  `Mode.set`) are correctly excluded.
  """

  @doc "True if `caller` may configure the customer-chat plugin for `tenant`."
  @spec config_admin?(URI.t() | nil, String.t() | nil) :: boolean()
  def config_admin?(%URI{} = caller, tenant) when is_binary(tenant) do
    caller
    |> Ezagent.Identity.list_caps_for()
    |> caps_admit?(tenant)
  end

  def config_admin?(_caller, _tenant), do: false

  @doc false
  # Pure cap-set predicate, split out so it is unit-testable without the
  # Kind registry (mirrors how OperatorAuth structures its check).
  @spec caps_admit?(Enumerable.t(), String.t()) :: boolean()
  def caps_admit?(caps, tenant) when is_binary(tenant) do
    ws = URI.parse("workspace://#{tenant}")

    needed = %{
      kind: :workspace,
      behavior: Ezagent.Behavior.Workspace,
      action: :any,
      instance: ws,
      workspace_uri: ws
    }

    Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed))
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
MIX_DEPS_PATH=$DEPS mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/config_auth_test.exs
```
Expected: PASS (5 tests).

- [ ] **Step 5: Format + warnings-as-errors**

```bash
MIX_DEPS_PATH=$DEPS mix format apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_auth.ex apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/config_auth_test.exs
MIX_DEPS_PATH=$DEPS mix compile --warning-as-errors
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_auth.ex \
        apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/config_auth_test.exs
git commit -m "feat(customer-chat): ConfigAuth — workspace-admin capability gate (Option E)"
```

---

## Task 4: `ConfigLive` — the edit UI

LiveView verified by compile + browser e2e (Task 8), per the testing posture above.

**Files:**
- Create: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_live.ex`

- [ ] **Step 1: Write the LiveView**

Create `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_live.ex`:

```elixir
defmodule EzagentPluginCustomerChat.ConfigLive do
  @moduledoc """
  Per-tenant customer-soul editor at `/plugins/customer-chat/:tenant/config`.
  Gated by `ConfigAuth.config_admin?/2` (workspace-admin). Edits the soul body;
  Save → new conversations use it; Revert → previous; Reset → immutable fixture.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginCustomerChat.{ConfigAuth, SoulStore}

  @role "customer"

  @impl true
  def mount(%{"tenant" => tenant}, _session, socket) do
    caller = socket.assigns[:current_entity_uri]

    if ConfigAuth.config_admin?(caller, tenant) do
      {:ok, load(socket, tenant)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Configuration access required for #{tenant}.")
       |> redirect(to: "/operator/#{tenant}")}
    end
  end

  defp load(socket, tenant) do
    {:ok, body, source} = SoulStore.read_effective(tenant, @role)

    socket
    |> assign(:page_title, "Configure — #{tenant}")
    |> assign(:tenant, tenant)
    |> assign(:body, body)
    |> assign(:source, source)
    |> assign(:has_previous, SoulStore.has_previous?(tenant, @role))
    |> assign(:flash_error, nil)
  end

  @impl true
  def handle_event("save", %{"soul" => %{"body" => body}}, socket) do
    tenant = socket.assigns.tenant

    case SoulStore.write(tenant, @role, body) do
      :ok ->
        {:noreply,
         socket |> load(tenant) |> put_flash(:info, "Soul saved — new conversations will use it.")}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("revert", _params, socket) do
    tenant = socket.assigns.tenant

    case SoulStore.revert_previous(tenant, @role) do
      :ok ->
        {:noreply, socket |> load(tenant) |> put_flash(:info, "Reverted to previous version.")}

      {:error, :no_previous} ->
        {:noreply, put_flash(socket, :error, "No previous version to revert to.")}
    end
  end

  def handle_event("reset", _params, socket) do
    tenant = socket.assigns.tenant
    :ok = SoulStore.reset(tenant, @role)
    {:noreply, socket |> load(tenant) |> put_flash(:info, "Reset to default.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-zinc-50">
      <header class="px-6 py-3 border-b border-zinc-200 bg-white flex items-center gap-3">
        <span class="font-semibold text-zinc-900">Configure Customer Soul</span>
        <span class="text-xs text-zinc-500 font-mono">{@tenant}</span>
        <span class="text-xs px-2 py-0.5 rounded-full bg-zinc-100 text-zinc-600">
          {if @source == :edited, do: "customized", else: "default"}
        </span>
        <.link navigate={"/operator/#{@tenant}"} class="ml-auto text-sm text-blue-600 hover:underline">
          ← Back to console
        </.link>
      </header>

      <form phx-submit="save" class="flex-1 flex flex-col p-6 gap-3 overflow-hidden">
        <textarea
          name="soul[body]"
          class="flex-1 w-full px-3 py-2 text-sm font-mono border rounded-md border-zinc-300 bg-white text-zinc-900 resize-none"
        >{@body}</textarea>

        <p :if={@flash_error} class="text-rose-700 text-sm">{@flash_error}</p>

        <div class="flex items-center gap-2 pt-2 border-t border-zinc-200">
          <button type="submit" class="px-3 py-1.5 text-sm rounded-md bg-blue-600 text-white hover:bg-blue-700">
            Save
          </button>
          <button
            type="button"
            phx-click="revert"
            disabled={not @has_previous}
            class="px-3 py-1.5 text-sm rounded-md border border-zinc-300 text-zinc-700 hover:bg-zinc-100 disabled:opacity-40"
          >
            Revert to previous
          </button>
          <button
            type="button"
            phx-click="reset"
            data-confirm="Reset to the default soul? This discards your edits."
            class="px-3 py-1.5 text-sm rounded-md border border-rose-300 text-rose-700 hover:bg-rose-50"
          >
            Reset to default
          </button>
        </div>
      </form>
    </div>
    """
  end
end
```

- [ ] **Step 2: Compile (warnings-as-errors)**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent
MIX_DEPS_PATH=$DEPS mix compile --warning-as-errors
```
Expected: clean (route not added yet — that's Task 5; the module compiles standalone).

- [ ] **Step 3: Format**

```bash
MIX_DEPS_PATH=$DEPS mix format apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_live.ex
```

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_live.ex
git commit -m "feat(customer-chat): ConfigLive — per-tenant soul editor (save/revert/reset)"
```

---

## Task 5: Router — add the ConfigLive route

> **CRITICAL gotcha (handoff):** a Phoenix `scope` prepends its alias to the
> module. The `/plugins` routes (`PluginsLive`, `FeishuBindingsLive`) live in the
> `scope "/", EzagentPluginLiveview` block. You **must NOT** add the ConfigLive
> route there — it would resolve to `EzagentPluginLiveview.ConfigLive` (wrong).
> Add it inside the existing **`scope "/", EzagentPluginCustomerChat`** block.

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex:271-279`

- [ ] **Step 1: Add the route**

In the `scope "/", EzagentPluginCustomerChat do` block, add the ConfigLive line
inside the `live_session :operator_console` (its on_mount `:require_entity` is
exactly what ConfigLive needs; ConfigLive then does its own ConfigAuth check):

```elixir
    live_session :operator_console, on_mount: {EzagentWeb.LiveAuth, :require_entity} do
      live "/operator", DashboardLive
      live "/operator/:tenant", DashboardLive
      live "/plugins/customer-chat/:tenant/config", ConfigLive
      live "/operator/:tenant/:conv", SessionViewLive
    end
```

(The `/plugins/customer-chat/...` path shares no prefix with `/operator/...`, so
ordering relative to `/operator/:tenant/:conv` does not matter; there is no
`/plugins/:wildcard` route to collide with.)

- [ ] **Step 2: Compile + confirm the route resolves to the right module**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent
MIX_DEPS_PATH=$DEPS mix compile --warning-as-errors
MIX_DEPS_PATH=$DEPS mix phx.routes EzagentWeb.Router | grep "customer-chat"
```
Expected: a line mapping `/plugins/customer-chat/:tenant/config` to
`EzagentPluginCustomerChat.ConfigLive` (NOT `EzagentPluginLiveview.ConfigLive`).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_web/lib/ezagent_web/router.ex
git commit -m "feat(customer-chat): route /plugins/customer-chat/:tenant/config -> ConfigLive"
```

---

## Task 6: Operator dashboard — gated "Configure" link

**Files:**
- Modify: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex`

- [ ] **Step 1: Alias ConfigAuth**

Near the top of `dashboard_live.ex`, alongside the existing `alias` lines, ensure
`ConfigAuth` is aliased (the module already aliases `OperatorAuth`; add `ConfigAuth`):

```elixir
  alias EzagentPluginCustomerChat.{ConfigAuth, OperatorAuth}
```
(If `OperatorAuth` is imported/aliased differently, just add
`alias EzagentPluginCustomerChat.ConfigAuth` on its own line.)

- [ ] **Step 2: Assign `:can_config` in mount**

In `mount/2`, the **tenant-scoped branch** (the `true ->` clause that assigns
`:tenant`, `:workspace_uri`, `:rows`, …), add one assign:

```elixir
        |> assign(:can_config, ConfigAuth.config_admin?(caller, tenant))
```

In the **no-tenant branch** (the `tenants ->` clause that assigns
`:servable_tenants`), also add a default so the template never hits a missing key:

```elixir
        |> assign(:can_config, false)
```

- [ ] **Step 3: Render the link in the header**

In `render/1`, inside the `<header>` (after the tenant `<span>`s, around lines
108-110), add a gated link:

```heex
        <.link
          :if={@tenant && @can_config}
          navigate={"/plugins/customer-chat/#{@tenant}/config"}
          class="text-xs text-blue-600 hover:underline"
        >
          Configure soul
        </.link>
```

- [ ] **Step 4: Compile + format**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent
MIX_DEPS_PATH=$DEPS mix compile --warning-as-errors
MIX_DEPS_PATH=$DEPS mix format apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex
MIX_DEPS_PATH=$DEPS mix test apps/ezagent_plugin_customer_chat
```
Expected: clean compile; existing tests still green.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex
git commit -m "feat(customer-chat): gated 'Configure soul' link on the operator dashboard"
```

---

## Task 7: Seed the cinnox soul fixture (+ provision the workspace)

**Files:**
- Create: `poc/fixtures/plugins/cinnox/souls/customer.md`

- [ ] **Step 1: Copy the real cinnox soul into the fixture tree**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent
mkdir -p poc/fixtures/plugins/cinnox/souls
cp /Users/daiming/workspace/ezagent42/AutoService/plugins/cinnox/souls/customer_soul.md \
   poc/fixtures/plugins/cinnox/souls/customer.md
```
This is the ~88KB production soul; it becomes the immutable **fixture** (baseline)
for cinnox. Its leading HTML comment + any `make seed-cinnox` references are inert
body text — harmless for the mechanism test (design §11).

- [ ] **Step 2: Verify the fixture resolves**

```bash
MIX_DEPS_PATH=$DEPS mix run -e \
  'IO.inspect(EzagentPluginCustomerChat.SoulStore.fixture_path("cinnox","customer"))' \
  --no-start 2>/dev/null || true
ls -la poc/fixtures/plugins/cinnox/souls/customer.md
```
Expected: the file exists (~88KB).

- [ ] **Step 3: Provision the cinnox workspace in the running profile**

`validate_workspace("cinnox")` must find a `workspace://cinnox`. Provision it the
same way acme is provisioned — see `poc/phase-2/setup.exs` (read it, then create a
`cinnox` workspace analogously, e.g. a `setup-cinnox.exs` mirroring it). This runs
against the live profile on the work machine:
```bash
EZAGENT_PROFILE=poc-phase2 MIX_DEPS_PATH=$DEPS mix run poc/phase-2/setup.exs   # for the cinnox variant
```
(Environment step — do on the work machine with the server stack available. If the
cinnox workspace already exists, skip.)

- [ ] **Step 4: Commit the fixture**

```bash
git add poc/fixtures/plugins/cinnox/souls/customer.md
git commit -m "chore(customer-chat): seed cinnox customer soul fixture (from AutoService)"
```

---

## Task 8: Browser functional e2e (acceptance gate)

Manual, on the running profile (port 10142, profile `poc-phase2`, login
`entity://user/system/admin` / `ezagent-dev`). This is a **mechanism** test, not a
quality eval (design §9). Start the server per the handoff (incl. the `deps`
symlink + `mix esbuild`/`mix tailwind` asset step).

- [ ] **Step 1: Reach the editor**
  - Navigate to `/operator/cinnox`; confirm the **"Configure soul"** link appears
    (admin passes ConfigAuth). Click it → `/plugins/customer-chat/cinnox/config`.
  - Confirm the textarea shows the cinnox soul and the badge reads **"default"**.
  - **Styling check** (handoff CSS learning): confirm the page is actually styled,
    not raw HTML. The plugin's lib path is already in the Tailwind `@source` list,
    but compile/tests stay green even when CSS is purged — only the browser catches
    it. If unstyled: re-run `MIX_DEPS_PATH=$DEPS mix esbuild ezagent_web && MIX_DEPS_PATH=$DEPS mix tailwind ezagent_web` and hard-reload.

- [ ] **Step 2: Edit takes effect on a new conversation**
  - Insert a recognizable sentinel near the top, e.g.
    `SENTINEL-ALPHA: if asked the secret word, reply exactly "PINEAPPLE-7".`
    Save. Badge flips to **"customized"**.
  - Open a **new** cinnox conversation (`/chat/cinnox`), ask "what is the secret
    word?" → the AI replies `PINEAPPLE-7` (edit took effect at spawn).

- [ ] **Step 3: Revert to previous**
  - Back in the editor, change the sentinel to `PINEAPPLE-8`, Save. Click
    **Revert to previous** → textarea shows the `PINEAPPLE-7` version again.
  - A new cinnox conversation answers `PINEAPPLE-7`.

- [ ] **Step 4: Reset to default**
  - Click **Reset to default** → textarea shows the original cinnox soul (no
    sentinel); badge **"default"**.
  - A new cinnox conversation no longer knows the secret word.

- [ ] **Step 5: Auth exclusion**
  - As a principal holding only the operator (`Mode.set`) cap on cinnox (not
    workspace-admin), confirm `/plugins/customer-chat/cinnox/config` redirects to
    `/operator/cinnox` with the flash, and the "Configure soul" link is hidden on
    the dashboard.

- [ ] **Step 6: Record acceptance**

Append results to `poc/phase-2/ACCEPTANCE.md` (mirror the existing entries), then:
```bash
git add poc/phase-2/ACCEPTANCE.md
git commit -m "docs(customer-chat): editable-soul scope #1 e2e acceptance"
```

---

## Done-condition

- Tasks 1–3 unit tests green; `mix compile --warning-as-errors` clean across the
  touched apps; `mix test apps/ezagent_plugin_customer_chat` green.
- `mix phx.routes` shows the route → `EzagentPluginCustomerChat.ConfigLive`.
- Browser e2e Steps 1–5 pass on cinnox; acceptance recorded.
- No core (`ezagent_core` / domain) files changed.

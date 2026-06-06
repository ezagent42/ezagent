# Agent Provisioning Cascade — PR-0 (Foundations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the security-critical foundations of the multi-level credential cascade — a versioned credential-grant store, a cap-checked user-default-credential-source registry, and the adapter secret/config path split — with NO cascade behavior change yet.

**Architecture:** Two new DB-backed projection tables in `ezagent_core` (`credential_grants`, `user_default_credential_sources`) modeled on the existing `Ezagent.ExternalMirror.BindingRow` pattern (pure-data Ecto schema + natural-key unique index + a thin store module), a grant-scoped system principal in the `SystemPrincipal.Catalog`, a `UriQuery` resolver for the user-source pointer, and a split of `Ezagent.Agent.CredentialAdapter`'s `credential_relpaths/0` into disjoint `secret_relpaths/0` (token material) + config paths (which join the normal layer merge in PR-2). No `resolve_layers`/materialization yet — PR-1/PR-2.

**Tech Stack:** Elixir/OTP umbrella, Ecto + SQLite (`EzagentCore.Repo`), CapBAC (`Ezagent.Capability`), `Ezagent.UriQuery` ETS registry, ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-06-agent-provisioning-cascade-design.md` (rev 4). This plan implements PR-0 from §9; §5.1 (grant), §5.2 (user source), §D6 (adapter split). PR-1..PR-4 get their own plans after PR-0 lands.

**Plan rev 3** — codex final-gate round (4 HIGH) folded: GrantCap derives `workspace_uri`
via `Capability.workspace_of/1` (a `workspace://` URI) so the cap actually matches the
dispatch + asserts `matches?/2`; Task 6 invariant drops the removed `credential_grant_uri`
and checks the cataloged `system://credential-materializer` instead; the user-source write
goes through a cap-checked **Behavior chokepoint** (`:set_default_credential_source`,
dispatch = cap-check + audit), with `set/4` as the action body (validation only) and
**adoption dispatching the same action** (no raw setter, no audit placeholder).

**Plan rev 2** — codex adversarial-review of rev 1 (1 CRIT + 2 HIGH + 1 MED) folded:
- CRIT: user-source write is now the AUTHORIZED, cap-checked + fully-validated path (Task 4 `set/5` takes caller/caps, validates owner/ws/flavor/source-kind/existence, audits) — not punted to the caller.
- HIGH: grant principal redesigned for the CLOSED Catalog + real `Capability.cap/5` — a cataloged materializer identity + a per-grant narrow derived read cap, NOT a dynamic `system://credential-grant/<id>` URI (Task 3).
- HIGH: grant lifecycle API added (`fetch_for_materialize/1`, `revalidate_version!/2`, scope/source-exists validation, `reapprove/1`) with revoke/delete/scope/TOCTOU tests (Task 2).
- MED: real module/API names (`Ezagent.PluginCc.Template.CcAgent`, `Ezagent.PluginCodex.Template.CodexAgent`, `EzagentCore.DataCase`, `Ezagent.URI.parse/1`).

**Conventions to follow (consult before coding):**
- Ecto schema + store: copy the shape of `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex` (string PK, `@timestamps_opts utc_datetime_usec`, natural-key unique index, `alias EzagentCore.Repo`).
- Migrations: `apps/ezagent_core/priv/repo/migrations/<UTC-stamp>_<name>.exs`; latest is `20260617000000_*`, so use a later stamp.
- Run a single test file: `cd /app && MIX_ENV=test mix test <path>` (or in the dev docker container per `docs/`); use `mix test <path>:<line>` for one test.
- Use `uv run` only for python; never bare `python`. Elixir is `mix`.

---

## Task 1: Adapter split — `secret_relpaths/0` distinct from config (spec §D6, H4)

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/agent/credential_adapter.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex:216`
- Modify: `apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex:36`
- Test: `apps/ezagent_core/test/invariants/credential_adapter_contract_test.exs` (existing — extend) + new `apps/ezagent_core/test/ezagent/agent/credential_adapter_split_test.exs`

- [ ] **Step 1: Write the failing test** (`credential_adapter_split_test.exs`)

```elixir
defmodule Ezagent.Agent.CredentialAdapterSplitTest do
  use ExUnit.Case, async: true

  # Every credentialled flavor must declare secret_relpaths/0, and the secret set
  # must be DISJOINT from the config paths (config.toml is config, not a secret — H4).
  test "cc/codex declare secret_relpaths and secrets are not config files" do
    for mod <- [Ezagent.PluginCc.Template.CcAgent, Ezagent.PluginCodex.Template.CodexAgent] do
      assert function_exported?(mod, :secret_relpaths, 0),
             "#{inspect(mod)} must implement secret_relpaths/0"
      secrets = mod.secret_relpaths()
      assert is_list(secrets) and secrets != []
      # config.toml is configuration, must NOT be a secret path
      refute "config.toml" in secrets
    end
  end

  test "cc secret is the credentials file; codex secret is auth.json only" do
    assert Ezagent.PluginCc.Template.CcAgent.secret_relpaths() == [".credentials.json"]
    assert Ezagent.PluginCodex.Template.CodexAgent.secret_relpaths() == ["auth.json"]
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test apps/ezagent_core/test/ezagent/agent/credential_adapter_split_test.exs`
Expected: FAIL — `secret_relpaths/0` undefined.

- [ ] **Step 3: Add the callback to the contract**

In `credential_adapter.ex`, add after `credential_relpaths/0`'s `@callback`:

```elixir
  @doc """
  The subset of files within the credential home that are pure SECRET/token material,
  copied ONLY from the single resolved credential source (§D6). Disjoint from config
  paths — codex `config.toml` is config (joins the layer merge), NOT a secret.
  """
  @callback secret_relpaths() :: [String.t()]
```

Add `{:secret_relpaths, 0}` to `@declarative_callbacks` so the all-or-none gate covers it.

- [ ] **Step 4: Implement in cc + codex**

`cc_agent.ex` (after line 216):

```elixir
  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: [".credentials.json"]
```

`codex_agent.ex` (after line 36) — drop `config.toml` from the secret set:

```elixir
  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: ["auth.json"]
```

(Leave `credential_relpaths/0` in place for now — PR-2 migrates its remaining readers; do NOT delete it in PR-0 to avoid touching the materializer.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/ezagent_core/test/ezagent/agent/credential_adapter_split_test.exs apps/ezagent_core/test/invariants/credential_adapter_contract_test.exs`
Expected: PASS (both). If the contract test enumerates declarative callbacks, it now also requires `secret_relpaths/0` — confirm cc/codex satisfy it.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/agent/credential_adapter.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex apps/ezagent_core/test/ezagent/agent/credential_adapter_split_test.exs
git commit -m "feat(#17 cascade PR-0): split secret_relpaths from config in CredentialAdapter (codex H4)"
```

---

## Task 2: `credential_grants` table + migration (spec §5.1)

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260618000000_credential_grants.exs`
- Create: `apps/ezagent_core/lib/ezagent/credential/grant_row.ex`
- Test: `apps/ezagent_core/test/ezagent/credential/grant_row_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.Credential.GrantRowTest do
  use EzagentCore.DataCase, async: false   # consult an existing *_test that uses the Repo sandbox
  alias Ezagent.Credential.GrantRow
  alias EzagentCore.Repo

  test "insert + get a grant; version starts at 1; agent_uri is unique" do
    attrs = %{
      agent_uri: "entity://team-a/agent/worker1",
      credential_source_uri: "entity://team-a/agent/alice-base",
      approved_by: "entity://team-a/user/alice",
      approved_scope: "entity://team-a/agent/alice-base",
      version: 1
    }
    assert {:ok, row} = GrantRow.insert(attrs)
    assert row.version == 1
    assert GrantRow.get_for_agent("entity://team-a/agent/worker1").id == row.id
    # one active grant per agent → second insert for same agent_uri collides
    assert {:error, _} = GrantRow.insert(attrs)
  end

  test "revoke bumps version and stamps revoked_at" do
    {:ok, row} = GrantRow.insert(%{agent_uri: "entity://team-a/agent/w2",
      credential_source_uri: "s", approved_by: "u", approved_scope: "s", version: 1})
    assert {:ok, revoked} = GrantRow.revoke(row.agent_uri)
    assert revoked.version == row.version + 1
    assert revoked.revoked_at != nil
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test apps/ezagent_core/test/ezagent/credential/grant_row_test.exs`
Expected: FAIL — module/table missing.

- [ ] **Step 3: Write the migration**

`20260618000000_credential_grants.exs`:

```elixir
defmodule EzagentCore.Repo.Migrations.CredentialGrants do
  use Ecto.Migration

  def change do
    create table(:credential_grants, primary_key: false) do
      add :id, :string, primary_key: true            # synthetic = agent_uri
      add :agent_uri, :string, null: false
      add :credential_source_uri, :string, null: false
      add :approved_by, :string, null: false
      add :approved_scope, :string, null: false
      add :version, :integer, null: false, default: 1
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credential_grants, [:agent_uri],
             name: :credential_grants_agent_uri_index)
  end
end
```

- [ ] **Step 4: Write the schema + store**

`grant_row.ex`:

```elixir
defmodule Ezagent.Credential.GrantRow do
  @moduledoc """
  Durable credential GRANT (spec §5.1). One active grant per agent: who approved it,
  the exact source URI + scope it was approved for, and a monotonic `version` bumped
  on revoke. Read at every materialization (PR-2) to re-validate before exec.
  Pattern mirrors `Ezagent.ExternalMirror.BindingRow`.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "credential_grants" do
    field :agent_uri, :string
    field :credential_source_uri, :string
    field :approved_by, :string
    field :approved_scope, :string
    field :version, :integer, default: 1
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Insert a new grant (id = agent_uri). Collides if an active grant exists."
  def insert(attrs) do
    %__MODULE__{}
    |> cast(Map.put(attrs, :id, attrs.agent_uri),
         [:id, :agent_uri, :credential_source_uri, :approved_by, :approved_scope, :version])
    |> validate_required([:id, :agent_uri, :credential_source_uri, :approved_by, :approved_scope])
    |> unique_constraint(:agent_uri, name: :credential_grants_agent_uri_index)
    |> Repo.insert()
  end

  @doc "The active grant for an agent, or nil."
  def get_for_agent(agent_uri), do: Repo.get(__MODULE__, agent_uri)

  @doc "Revoke: bump version, stamp revoked_at. Idempotent-ish (raises if absent)."
  def revoke(agent_uri) do
    case Repo.get(__MODULE__, agent_uri) do
      nil -> {:error, :no_grant}
      row ->
        row
        |> change(version: row.version + 1, revoked_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  @doc "True iff the grant exists and is not revoked."
  def active?(agent_uri) do
    case get_for_agent(agent_uri) do
      %__MODULE__{revoked_at: nil} -> true
      _ -> false
    end
  end

  @doc \"\"\"
  Materialize-facing fetch (codex H3'): returns `{:ok, source_uri, version}` ONLY for an
  active, non-revoked grant whose `approved_scope` still matches the source's identity AND
  whose source still exists; else `{:error, reason}` (`:revoked` | `:no_grant` |
  `:source_not_found` | `:scope_mismatch`). The returned `version` is the value to
  re-check immediately before exec (revalidate_version!/2).
  \"\"\"
  def fetch_for_materialize(agent_uri) do
    case get_for_agent(agent_uri) do
      nil -> {:error, :no_grant}
      %__MODULE__{revoked_at: r} when not is_nil(r) -> {:error, :revoked}
      %__MODULE__{} = g ->
        cond do
          g.approved_scope != g.credential_source_uri -> {:error, :scope_mismatch}
          not source_exists?(g.credential_source_uri) -> {:error, :source_not_found}
          true -> {:ok, g.credential_source_uri, g.version}
        end
    end
  end

  @doc \"\"\"
  TOCTOU re-check (codex H1'): call immediately before subprocess exec / curl-slice write
  with the `version` from fetch_for_materialize/2. Returns :ok iff the grant is still
  present, not revoked, AND its version is unchanged; else `{:error, :grant_changed}` —
  the caller MUST abort the start (do NOT launch with the now-stale secret).
  \"\"\"
  def revalidate_version!(agent_uri, version) do
    case get_for_agent(agent_uri) do
      %__MODULE__{revoked_at: nil, version: ^version} -> :ok
      _ -> {:error, :grant_changed}
    end
  end

  @doc \"\"\"
  Re-approve / replace a grant for an agent (e.g. after revoke, owner re-approves a
  source). Upsert by agent_uri, bumping version so any in-flight start re-validating the
  OLD version aborts. Cap-check the re-approval at the calling Behavior (same as insert).
  \"\"\"
  def reapprove(attrs) do
    prev = get_for_agent(attrs.agent_uri)
    next_version = if prev, do: prev.version + 1, else: 1

    %__MODULE__{}
    |> cast(Map.merge(attrs, %{id: attrs.agent_uri, version: next_version, revoked_at: nil}),
         [:id, :agent_uri, :credential_source_uri, :approved_by, :approved_scope, :version, :revoked_at])
    |> validate_required([:id, :agent_uri, :credential_source_uri, :approved_by, :approved_scope])
    |> Repo.insert(on_conflict: {:replace, [:credential_source_uri, :approved_by,
         :approved_scope, :version, :revoked_at, :updated_at]}, conflict_target: :id)
  end

  # source_exists?/1 — KindRegistry.lookup(uri) != :error OR a snapshot row exists.
  # Consult `Ezagent.KindRegistry` / the snapshot store for the canonical existence check.
  defp source_exists?(source_uri) do
    match?({:ok, _}, Ezagent.KindRegistry.lookup(Ezagent.URI.parse!(source_uri)))
  end
end
```

Add these tests to `grant_row_test.exs` (the H1'/H3' lifecycle invariants):

```elixir
  test "fetch_for_materialize fails for a revoked grant, returns source+version when active" do
    {:ok, g} = GrantRow.insert(%{agent_uri: "entity://team-a/agent/m1",
      credential_source_uri: "entity://team-a/agent/alice-base",
      approved_by: "u", approved_scope: "entity://team-a/agent/alice-base", version: 1})
    # alice-base must exist as a Kind in setup for source_exists? to pass
    assert {:ok, "entity://team-a/agent/alice-base", 1} = GrantRow.fetch_for_materialize(g.agent_uri)
    {:ok, _} = GrantRow.revoke(g.agent_uri)
    assert {:error, :revoked} = GrantRow.fetch_for_materialize(g.agent_uri)
  end

  test "fetch_for_materialize fails when approved_scope != the source (grant for A used for B)" do
    {:ok, g} = GrantRow.insert(%{agent_uri: "entity://team-a/agent/m2",
      credential_source_uri: "entity://team-a/agent/B", approved_by: "u",
      approved_scope: "entity://team-a/agent/A", version: 1})
    assert {:error, :scope_mismatch} = GrantRow.fetch_for_materialize(g.agent_uri)
  end

  test "revalidate_version! aborts when revoked AFTER the precheck (TOCTOU)" do
    {:ok, g} = GrantRow.insert(%{agent_uri: "entity://team-a/agent/m3",
      credential_source_uri: "s", approved_by: "u", approved_scope: "s", version: 1})
    assert :ok = GrantRow.revalidate_version!(g.agent_uri, 1)
    {:ok, _} = GrantRow.revoke(g.agent_uri)              # revoke bumps version + stamps
    assert {:error, :grant_changed} = GrantRow.revalidate_version!(g.agent_uri, 1)
  end

  test "reapprove replaces a revoked grant and bumps version" do
    {:ok, g} = GrantRow.insert(%{agent_uri: "entity://team-a/agent/m4",
      credential_source_uri: "s", approved_by: "u", approved_scope: "s", version: 1})
    {:ok, _} = GrantRow.revoke(g.agent_uri)
    {:ok, re} = GrantRow.reapprove(%{agent_uri: g.agent_uri,
      credential_source_uri: "s2", approved_by: "u", approved_scope: "s2"})
    assert re.revoked_at == nil and re.version >= g.version + 2
  end
```

> NOTE: `DateTime.utc_now()` is fine in lib code (the no-`Date.now()` rule is a workflow-script constraint, not an app-code one). Confirm `Ezagent.DataCase` exists (search `test/support`); if the project uses a different Repo-sandbox case template, use that.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix ecto.migrate -r EzagentCore.Repo` (test env auto-migrates via the DataCase setup in most configs; if not, run migrate) then
`mix test apps/ezagent_core/test/ezagent/credential/grant_row_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_core/priv/repo/migrations/20260618000000_credential_grants.exs apps/ezagent_core/lib/ezagent/credential/grant_row.ex apps/ezagent_core/test/ezagent/credential/grant_row_test.exs
git commit -m "feat(#17 cascade PR-0): versioned credential_grants store (spec §5.1)"
```

---

## Task 3: Grant-scoped system principal (spec §5.1)

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`
- Test: `apps/ezagent_core/test/ezagent/system_principal/grant_scoped_test.exs`

> **Codex H1 redesign.** `SystemPrincipal` is a CLOSED allowlist: `Catalog.caps_for!/1`
> RAISES for unknown `system://` URIs, so a per-grant dynamic URI like
> `system://credential-grant/<id>` CANNOT be ad-hoc. And `Capability.cap/3` is
> `(kind, behavior, action)` (wildcards instance+workspace) — the narrow, source-scoped
> form is `Capability.cap/5` `(kind, behavior, action, instance, workspace_uri)`.
> So: a SINGLE cataloged materializer IDENTITY (for audit), and least-privilege enforced
> by a **narrow `cap/5` derived per-grant at call time** and passed as the dispatch caps —
> NOT a per-grant catalog entry, NOT a broad standing cap.

- [ ] **Step 1: Read the contracts first.** `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` (closed allowlist; `caps_for!/1` raises, `member?/1`), `apps/ezagent_core/lib/ezagent/capability.ex:118,138` (`cap/3` vs `cap/5`), and `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex` `resolve_source_config_dir/2` (the existing `--from` source `:read` dispatch — gives the exact `(kind, behavior_module, :read)` triple that authorizes a source read).

- [ ] **Step 2: Add the materializer identity to the Catalog**

In `catalog.ex`, add a cataloged identity `system://credential-materializer` with a MINIMAL standing cap set (audit identity only — it does NOT hold broad sandbox.read; the per-source authority comes from the derived cap in Step 4). Add a test that `Catalog.member?(parse("system://credential-materializer"))` is true and `caps_for!/1` does not raise for it.

- [ ] **Step 3: Write the failing test** (`grant_scoped_test.exs`)

```elixir
defmodule Ezagent.Credential.GrantCapTest do
  use ExUnit.Case, async: true
  alias Ezagent.Credential.GrantCap

  test "derives a narrow read cap that MATCHES the real sandbox.read dispatch needed-cap" do
    source = Ezagent.URI.parse!("entity://team-a/agent/alice-base")
    cap = GrantCap.read_cap_for(source)
    # scoped, not wildcard
    assert %Ezagent.Capability{action: :read, instance: ^source} = cap
    assert cap.workspace_uri != :any and cap.instance != :any
    # the cap the dispatch will check for `sandbox.read` on source — build it the SAME
    # way the runtime does and assert our derived cap satisfies it (consult kind/runtime.ex
    # for how the needed-cap is constructed for a :read dispatch).
    needed = Ezagent.Capability.cap(:agent, Ezagent.Behavior.Sandbox, :read, source,
               Ezagent.Capability.workspace_of(source))
    assert Ezagent.Capability.matches?(cap, needed)
  end
end
```

- [ ] **Step 4: Implement `Ezagent.Credential.GrantCap`** (derive the narrow cap; use the real `(kind, behavior_module, :read)` from Step 1)

```elixir
defmodule Ezagent.Credential.GrantCap do
  @moduledoc "Derives the least-privilege source-read cap for a validated credential grant (spec §5.1, codex H1). Caller passes this single cap as the dispatch caps for the source read — never a broad set."
  @doc \"\"\"
  A narrow source-read cap scoped to exactly `source_uri`. The workspace MUST be derived
  the SAME way the dispatch derives it — `Ezagent.Capability.workspace_of/1` returns a
  `workspace://<ws>` URI, and `Capability.matches?/2` requires exact workspace-URI equality
  (codex: a raw `"team-a"` string would NOT match → read denied).
  \"\"\"
  def read_cap_for(%URI{} = source_uri) do
    ws_uri = Ezagent.Capability.workspace_of(source_uri)   # %URI{scheme: "workspace"}
    # (kind, behavior_module, :read) per the --from source-read dispatch (Step 1 consult).
    Ezagent.Capability.cap(:agent, Ezagent.Behavior.Sandbox, :read, source_uri, ws_uri)
  end
end
```

> Confirm the exact `(kind, behavior_module)` for a source `:read` against
> `resolve_source_config_dir/2`'s dispatch + the BehaviorRegistry entry that serves `:read`.
> The test (Step 3) MUST assert the derived cap actually `Capability.matches?/2` the
> needed-cap the dispatch builds for `sandbox.read` on `source_uri` — not just field shape.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/ezagent_core/test/ezagent/credential/grant_scoped_test.exs apps/ezagent_core/test/ezagent/system_principal/`
Expected: PASS. Adjust assertion fields to the real `%Capability{}` shape (`kind/behavior/action/instance/workspace_uri`).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/system_principal* apps/ezagent_core/test/ezagent/system_principal/grant_scoped_test.exs
git commit -m "feat(#17 cascade PR-0): grant-scoped materialize principal (sandbox.read only, spec §5.1)"
```

---

## Task 4: `user_default_credential_sources` registry — table + cap-checked store + UriQuery resolver (spec §5.2)

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260618000100_user_default_credential_sources.exs`
- Create: `apps/ezagent_core/lib/ezagent/credential/user_default_source.ex`
- Test: `apps/ezagent_core/test/ezagent/credential/user_default_source_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.Credential.UserDefaultSourceTest do
  use EzagentCore.DataCase, async: false
  alias Ezagent.Credential.UserDefaultSource, as: UDS

  @owner "entity://team-a/user/alice"
  @ws "team-a"
  # setup/0 (consult an existing agent-fixture helper) must create cc-flavor agents
  # owned by alice in team-a: "alice-base" + "alice-base2"; a cc agent owned by BOB:
  # "bob-base"; a codex agent owned by alice: "alice-codex". `owner_caps/0` = alice's
  # own caps; `admin_caps/0` = system admin caps; `stranger_caps/0` = unrelated caps.

  # --- set/4 (action BODY: validation + persist), called directly ---
  test "valid source: sets + resolves; re-set upserts (unique per owner/ws/flavor)" do
    src = "entity://team-a/agent/alice-base"
    assert {:ok, _} = UDS.set(@owner, @ws, "cc", src)
    assert UDS.resolve(@owner, @ws, "cc") == src
    src2 = "entity://team-a/agent/alice-base2"
    assert {:ok, _} = UDS.set(@owner, @ws, "cc", src2)
    assert UDS.resolve(@owner, @ws, "cc") == src2
  end

  test "rejects a source owned by another user in the same workspace (codex H4)" do
    assert {:error, :source_owner_mismatch} = UDS.set(@owner, @ws, "cc", "entity://team-a/agent/bob-base")
  end

  test "rejects a source of the wrong flavor" do
    assert {:error, :source_flavor_mismatch} = UDS.set(@owner, @ws, "cc", "entity://team-a/agent/alice-codex")
  end

  test "rejects a cross-workspace source" do
    assert {:error, :source_workspace_mismatch} = UDS.set(@owner, @ws, "cc", "entity://team-b/agent/x")
  end

  test "rejects a non-existent source" do
    assert {:error, :source_not_found} = UDS.set(@owner, @ws, "cc", "entity://team-a/agent/ghost")
  end

  test "absent pointer resolves to nil (caller falls through to workspace-shared, not crash)" do
    assert UDS.resolve(@owner, @ws, "codex") == nil
  end
end
```

And a Behavior/dispatch test (auth + audit — the authorized chokepoint, codex CRIT):

```elixir
defmodule Ezagent.Credential.SetDefaultSourceBehaviorTest do
  use EzagentCore.DataCase, async: false
  # dispatch the :set_default_credential_source action via Ezagent.Router (consult an
  # existing WorkspaceUserAdmin dispatch test for the Cmd/ctx + caps fixtures).

  test "owner (or admin) can set; a stranger is denied :unauthorized by CapBAC" do
    # owner caps → {:ok, _}; stranger caps → {:error, :unauthorized}
  end

  test "a successful dispatch writes an audit row" do
    # assert against the project's real audit sink (the dispatch path audits — consult
    # how WorkspaceUserAdmin :create_user audit is asserted).
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test apps/ezagent_core/test/ezagent/credential/user_default_source_test.exs`
Expected: FAIL — module/table missing.

- [ ] **Step 3: Migration** (`20260618000100_user_default_credential_sources.exs`):

```elixir
defmodule EzagentCore.Repo.Migrations.UserDefaultCredentialSources do
  use Ecto.Migration

  def change do
    create table(:user_default_credential_sources, primary_key: false) do
      add :id, :string, primary_key: true       # "<owner>|<workspace>|<flavor>"
      add :owner_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :flavor, :string, null: false
      add :source_uri, :string, null: false
      add :set_by, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_default_credential_sources, [:owner_uri, :workspace_uri, :flavor],
             name: :user_default_credential_sources_natural_key_index)
  end
end
```

- [ ] **Step 4: Schema + store** (`user_default_source.ex`):

```elixir
defmodule Ezagent.Credential.UserDefaultSource do
  @moduledoc """
  The user's default credential source per (owner, workspace, flavor) — the §5.2
  source-of-truth POINTER (not a naming convention). Pointed source is validated to be
  in the same workspace; writes are cap-checked by the caller (see `set/5`). Queried via
  `Ezagent.UriQuery` (:user_default_credential_source) and by `pick_credential_source`
  in PR-1.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "user_default_credential_sources" do
    field :owner_uri, :string
    field :workspace_uri, :string
    field :flavor, :string
    field :source_uri, :string
    field :set_by, :string
    timestamps()
  end

  defp id(owner, ws, flavor), do: "#{owner}|#{ws}|#{flavor}"

  @doc \"\"\"
  Action BODY for setting the default source — VALIDATION + persist only. This is NOT a
  public unauthenticated setter: the AUTHORIZED entry point is the cap-checked Behavior
  action `:set_default_credential_source` (see below), dispatched via `Ezagent.Router`,
  which performs the cap-check AND the audit automatically (the dispatch path writes the
  audit row — consult `Ezagent.Behavior.WorkspaceUserAdmin` `:create_user` for the
  cap-check + audit pattern). `set/4` is reachable ONLY from that action body and from the
  adoption action (Task 5), which also dispatches — there is no raw cap-less call site
  (closes codex CRIT: single cap-checked + audited chokepoint).

  Validation (all required, fail loud):
    1. source parses + exists (KindRegistry lookup) — else `{:error, :source_not_found}`;
    2. source's workspace == `ws` — else `{:error, :source_workspace_mismatch}`;
    3. source belongs to `owner` (lineage/owner of the source agent == owner, via
       `Ezagent.AgentLineage` / the source's owner attr) — else `{:error, :source_owner_mismatch}`
       (blocks redirect to another user's same-workspace agent);
    4. source's flavor == `flavor` (via `Ezagent.UriQuery.resolve(:flavor, source)`) — else
       `{:error, :source_flavor_mismatch}`.
  \"\"\"
  def set(owner, ws, flavor, source_uri) do
    with {:ok, source} <- Ezagent.URI.parse(source_uri),
         :ok <- validate_source(source, owner, ws, flavor) do
      %__MODULE__{}
      |> cast(%{id: id(owner, ws, flavor), owner_uri: owner, workspace_uri: ws,
                flavor: flavor, source_uri: source_uri, set_by: owner},
              [:id, :owner_uri, :workspace_uri, :flavor, :source_uri, :set_by])
      |> validate_required([:id, :owner_uri, :workspace_uri, :flavor, :source_uri, :set_by])
      |> Repo.insert(on_conflict: {:replace, [:source_uri, :set_by, :updated_at]},
                     conflict_target: :id)
    end
  end

  # validate_source/4 — implements checks 1-4; returns :ok | {:error, reason}. Tests drive it.
```

**The authorized chokepoint** — add a Behavior action `:set_default_credential_source`
(on the User Kind, mirroring `Ezagent.Behavior.WorkspaceUserAdmin`): its `invoke/…`
runs under CapBAC (caller must be the owner OR hold the admin/manage cap) and the
dispatch path emits the audit row; the action body calls `UserDefaultSource.set/4`. The
Behavior is the ONLY public way to write the pointer. Tests below exercise it via
`Ezagent.Router.dispatch` (auth + audit), plus `set/4` directly for the validation cases.

```elixir
  # (Behavior sketch — place in the User-Kind behavior app; consult WorkspaceUserAdmin)
  # def invoke(:set_default_credential_source, %{flavor: f, source_uri: s} = args, ctx) do
  #   # ctx.caller + ctx.caps already cap-checked by the dispatch layer for this action+cap;
  #   # the action's cap subject = own-user-or-admin. Then:
  #   UserDefaultSource.set(ctx.self_uri_owner, workspace_of(ctx), f, s)
  # end

  @doc "Resolve the source URI, or nil if unset (caller falls through to workspace-shared)."
  def resolve(owner, ws, flavor) do
    case Repo.get(__MODULE__, id(owner, ws, flavor)) do
      %__MODULE__{source_uri: s} -> s
      nil -> nil
    end
  end

  # The pointed source's workspace segment must equal `ws` (use the canonical URI accessor,
  # NOT string parsing — Ezagent.URI.workspace_name!/1).
  defp validate_source_workspace(source_uri, ws) do
    case Ezagent.URI.parse(source_uri) do
      {:ok, u} ->
        if Ezagent.URI.workspace_name!(u) == ws, do: :ok, else: {:error, :source_workspace_mismatch}
      _ -> {:error, :bad_source_uri}
    end
  end
end
```

> Consult `apps/ezagent_core/lib/ezagent/uri.ex` for the exact accessor (`workspace_name!/1` / `workspace_of/1`) and `new/1` vs `new!/1`.

- [ ] **Step 5: Register the UriQuery resolver**

In the domain that owns credential resolution (e.g. extend
`apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/uri_query_resolvers.ex`'s
`register/0`):

```elixir
:ok = maybe_register(:user_default_credential_source, &__MODULE__.resolve_user_default_source/1)
```

with (resolver takes a `{owner, ws, flavor}` tuple per UriQuery's 1-arg resolver shape):

```elixir
def resolve_user_default_source({owner, ws, flavor}) do
  case Ezagent.Credential.UserDefaultSource.resolve(owner, ws, flavor) do
    nil -> :none
    s -> {:ok, s}
  end
end
```

> Match the existing resolver return convention in that file (`:none` / `{:ok, _}`); copy `resolve_session_template/1`'s shape.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test apps/ezagent_core/test/ezagent/credential/user_default_source_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_core/priv/repo/migrations/20260618000100_user_default_credential_sources.exs apps/ezagent_core/lib/ezagent/credential/user_default_source.ex apps/ezagent_core/test/ezagent/credential/user_default_source_test.exs apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/uri_query_resolvers.ex
git commit -m "feat(#17 cascade PR-0): cap-checked user_default_credential_source registry + UriQuery resolver (spec §5.2)"
```

---

## Task 5: Migration command — adopt existing creds, refuse ambiguity (spec §5.2)

**Files:**
- Create: `apps/ezagent_core/lib/mix/tasks/ezagent.credential.adopt.ex`
- Test: `apps/ezagent_core/test/ezagent/credential/adopt_test.exs` (test the underlying function, not the Mix wrapper)

- [ ] **Step 1: Write the failing test** (test a pure `adopt/3` fn the task wraps)

```elixir
defmodule Ezagent.Credential.AdoptTest do
  use EzagentCore.DataCase, async: false
  alias Ezagent.Credential.{Adopt, UserDefaultSource}

  # setup must create cc agent "alice-base" owned by alice in team-a (so validation passes).
  # admin_caps/0 = operator/admin caps; stranger_caps/0 = unrelated.

  test "adopts a single unambiguous existing source via the authorized dispatch" do
    candidates = ["entity://team-a/agent/alice-base"]
    assert {:ok, "entity://team-a/agent/alice-base"} =
             Adopt.adopt("entity://team-a/user/alice", "team-a", "cc", candidates,
               caller: "system://admin", caps: admin_caps())
    assert UserDefaultSource.resolve("entity://team-a/user/alice", "team-a", "cc") ==
             "entity://team-a/agent/alice-base"
  end

  test "REFUSES when multiple candidates are ambiguous (no silent guess)" do
    candidates = ["entity://team-a/agent/a1", "entity://team-a/agent/a2"]
    assert {:error, {:ambiguous, ^candidates}} =
             Adopt.adopt("entity://team-a/user/alice", "team-a", "cc", candidates,
               caller: "system://admin", caps: admin_caps())
  end

  test "adoption with non-operator caps is denied by the dispatch (no bypass)" do
    candidates = ["entity://team-a/agent/alice-base"]
    assert {:error, :unauthorized} =
             Adopt.adopt("entity://team-a/user/alice", "team-a", "cc", candidates,
               caller: "entity://team-a/user/eve", caps: stranger_caps())
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test apps/ezagent_core/test/ezagent/credential/adopt_test.exs`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Ezagent.Credential.Adopt`**

```elixir
defmodule Ezagent.Credential.Adopt do
  @moduledoc "One-time migration: adopt an existing per-agent credential as a user's default source (§5.2). Refuses ambiguity rather than guessing. Writes go through the SAME authorized, cap-checked, audited chokepoint (the :set_default_credential_source Behavior dispatch) — NOT a raw setter (codex CRIT: no unauthenticated side path)."

  @spec adopt(String.t(), String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def adopt(owner, ws, flavor, candidates, opts) do
    operator = Keyword.fetch!(opts, :caller)   # operator/admin principal
    caps = Keyword.fetch!(opts, :caps)

    case candidates do
      [single] ->
        # dispatch the authorized action (cap-check + audit + validation), as the
        # operator, targeting `owner`'s default. Consult Router/Cmd shape + the
        # :set_default_credential_source action's args.
        cmd = Ezagent.Cmd.new(
          Ezagent.URI.parse!(owner), :set_default_credential_source,
          %{flavor: flavor, source_uri: single, workspace: ws},
          %{caller: operator, caps: caps})

        case Ezagent.Router.dispatch(cmd) do
          {:ok, _} -> {:ok, single}
          err -> err
        end

      [] -> {:error, :no_candidate}
      many -> {:error, {:ambiguous, many}}
    end
  end
end
```

The Mix task `ezagent.credential.adopt` discovers candidates (existing agents owned by `owner` in `ws` with `flavor` that have credentials), builds the operator principal + caps (admin), and calls `adopt/5`, printing the `:ambiguous` list for the operator to resolve with an explicit `--source`. (Candidate discovery: reuse the agent listing already used by `mix ezagent` user/agent tasks; keep the task thin.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_core/test/ezagent/credential/adopt_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/credential/adopt.ex apps/ezagent_core/lib/mix/tasks/ezagent.credential.adopt.ex apps/ezagent_core/test/ezagent/credential/adopt_test.exs
git commit -m "feat(#17 cascade PR-0): credential adoption migration — refuses ambiguity (spec §5.2)"
```

---

## Task 6: PR-0 acceptance — invariant test that the foundations exist + are wired

**Files:**
- Test: `apps/ezagent_core/test/invariants/cascade_pr0_foundations_test.exs`

- [ ] **Step 1: Write the test**

```elixir
defmodule Ezagent.Invariants.CascadePr0FoundationsTest do
  use ExUnit.Case, async: true

  test "grant store, user-source registry, grant cap, adapter split all present" do
    assert Code.ensure_loaded?(Ezagent.Credential.GrantRow)
    assert Code.ensure_loaded?(Ezagent.Credential.UserDefaultSource)
    assert function_exported?(Ezagent.Credential.GrantCap, :read_cap_for, 1)
    # the cataloged materializer identity exists; the REJECTED per-grant dynamic principal does NOT
    assert Ezagent.SystemPrincipal.Catalog.member?(
             Ezagent.URI.parse!("system://credential-materializer"))
    refute function_exported?(Ezagent.SystemPrincipal, :credential_grant_uri, 1)
    assert function_exported?(Ezagent.PluginCc.Template.CcAgent, :secret_relpaths, 0)
    # secret/config disjoint per flavor (H4 invariant)
    assert "config.toml" not in Ezagent.PluginCodex.Template.CodexAgent.secret_relpaths()
  end

  test ":user_default_credential_source is a registered UriQuery attribute" do
    # registration happens at app boot; resolve returns the no-resolver error only if unregistered
    refute match?({:error, {:no_resolver, _}},
             Ezagent.UriQuery.resolve(:user_default_credential_source,
               {"entity://team-a/user/nobody", "team-a", "cc"}))
  end
end
```

- [ ] **Step 2: Run + verify pass**

Run: `mix test apps/ezagent_core/test/invariants/cascade_pr0_foundations_test.exs`
Expected: PASS (boot registers the resolver; the others are compile-time present).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_core/test/invariants/cascade_pr0_foundations_test.exs
git commit -m "test(#17 cascade PR-0): foundations-present invariant"
```

---

## PR-0 close-out

- [ ] Run the touched apps' suites: `mix test apps/ezagent_core apps/ezagent_plugin_cc apps/ezagent_plugin_codex`
- [ ] Open PR, run `/codex:review`, address findings, admin-merge.
- [ ] **Next plan:** PR-1 (resolution core — `resolve_layers` + `pick_credential_source` state machine D4.3 + grant authorize/re-validate), then PR-2 (layered materialize + atomic-replace-with-rollback + tombstone trust), per spec §9.

## What PR-0 deliberately does NOT do (deferred)
- No `resolve_layers`, no cascade merge, no materialization change (PR-1/PR-2).
- No removal of `credential_relpaths/0` (PR-2 migrates its readers).
- No workspace-shared service-account source storage (PR-3/PR-4).
- Grant revocation propagation to running agents (force-restart) is PR-2 (needs the materialize/restart path).

# Agent Provisioning Cascade — PR-0 (Foundations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the security-critical foundations of the multi-level credential cascade — a versioned credential-grant store, a cap-checked user-default-credential-source registry, and the adapter secret/config path split — with NO cascade behavior change yet.

**Architecture:** Two new DB-backed projection tables in `ezagent_core` (`credential_grants`, `user_default_credential_sources`) modeled on the existing `Ezagent.ExternalMirror.BindingRow` pattern (pure-data Ecto schema + natural-key unique index + a thin store module), a grant-scoped system principal in the `SystemPrincipal.Catalog`, a `UriQuery` resolver for the user-source pointer, and a split of `Ezagent.Agent.CredentialAdapter`'s `credential_relpaths/0` into disjoint `secret_relpaths/0` (token material) + config paths (which join the normal layer merge in PR-2). No `resolve_layers`/materialization yet — PR-1/PR-2.

**Tech Stack:** Elixir/OTP umbrella, Ecto + SQLite (`EzagentCore.Repo`), CapBAC (`Ezagent.Capability`), `Ezagent.UriQuery` ETS registry, ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-06-agent-provisioning-cascade-design.md` (rev 4). This plan implements PR-0 from §9; §5.1 (grant), §5.2 (user source), §D6 (adapter split). PR-1..PR-4 get their own plans after PR-0 lands.

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
    for mod <- [EzagentPluginCc.Template.CcAgent, EzagentPluginCodex.Template.CodexAgent] do
      assert function_exported?(mod, :secret_relpaths, 0),
             "#{inspect(mod)} must implement secret_relpaths/0"
      secrets = mod.secret_relpaths()
      assert is_list(secrets) and secrets != []
      # config.toml is configuration, must NOT be a secret path
      refute "config.toml" in secrets
    end
  end

  test "cc secret is the credentials file; codex secret is auth.json only" do
    assert EzagentPluginCc.Template.CcAgent.secret_relpaths() == [".credentials.json"]
    assert EzagentPluginCodex.Template.CodexAgent.secret_relpaths() == ["auth.json"]
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
  use Ezagent.DataCase, async: false   # consult an existing *_test that uses the Repo sandbox
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

- [ ] **Step 1: Read the catalog first.** Open `catalog.ex` and the `Ezagent.SystemPrincipal` module to learn how a principal URI maps to a closed cap set (`SystemPrincipal.caps/1`) and how `system://bootstrap` is defined. The grant-scoped principal must hold ONLY `sandbox.read` on the grant's `approved_scope` — not a blanket catalog entry.

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Ezagent.SystemPrincipal.GrantScopedTest do
  use ExUnit.Case, async: true
  alias Ezagent.SystemPrincipal

  test "grant-scoped principal holds only sandbox.read on the approved source" do
    source = "entity://team-a/agent/alice-base"
    uri = SystemPrincipal.credential_grant_uri("grant-123")
    caps = SystemPrincipal.grant_caps(uri, source)
    # exactly one cap: sandbox.read on `source`
    assert Enum.count(caps) == 1
    cap = Enum.at(caps, 0)
    assert cap.behavior == :sandbox or cap.action == :read   # match the real Capability shape
    refute Enum.any?(caps, fn c -> c.action == :write end)
  end
end
```

- [ ] **Step 3: Implement** — add to `SystemPrincipal` (and a catalog note):

```elixir
  @doc "URI for the principal that materializes under a specific credential grant."
  def credential_grant_uri(grant_id), do: "system://credential-grant/#{grant_id}"

  @doc \"\"\"
  The closed cap set for a grant-scoped materialize principal: ONLY `sandbox.read`
  on the grant's approved source URI. Never blanket system caps (spec §5.1 / codex H1).
  \"\"\"
  def grant_caps(_grant_uri, approved_source_uri) do
    [Ezagent.Capability.cap(:sandbox, :read, approved_source_uri)]   # confirm cap/3 arity+shape
  end
```

> Consult `apps/ezagent_core/lib/ezagent/capability.ex` for the exact `cap/…` builder (it has a kind/behavior/instance/workspace + the new action axis per docs/futures/todo). Build a cap that authorizes `:read` on `approved_source_uri` and NOTHING else.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_core/test/ezagent/system_principal/grant_scoped_test.exs`
Expected: PASS. Adjust the assertion fields to the real `%Capability{}` shape.

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
  use Ezagent.DataCase, async: false
  alias Ezagent.Credential.UserDefaultSource, as: UDS

  @owner "entity://team-a/user/alice"
  @ws "team-a"

  test "set + resolve a default source; unique per (owner, workspace, flavor)" do
    src = "entity://team-a/agent/alice-base"
    assert {:ok, _} = UDS.set(@owner, @ws, "cc", src, set_by: @owner)
    assert UDS.resolve(@owner, @ws, "cc") == src
    # uniqueness: re-set updates (upsert), does not duplicate
    src2 = "entity://team-a/agent/alice-base2"
    assert {:ok, _} = UDS.set(@owner, @ws, "cc", src2, set_by: @owner)
    assert UDS.resolve(@owner, @ws, "cc") == src2
  end

  test "rejects a pointer to a source in another workspace" do
    cross = "entity://team-b/agent/x"
    assert {:error, :source_workspace_mismatch} =
             UDS.set(@owner, @ws, "cc", cross, set_by: @owner)
  end

  test "absent pointer resolves to nil (caller decides fall-through, not crash)" do
    assert UDS.resolve(@owner, @ws, "codex") == nil
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
  Set/replace the default source. Validates the pointed source's workspace matches `ws`
  (reject cross-workspace redirect — codex H4). CALLER must have already cap-checked that
  `set_by` may write this owner's default (owner or admin) — assert that upstream in the
  Behavior that calls this; this module enforces the data invariants.
  \"\"\"
  def set(owner, ws, flavor, source_uri, opts) do
    set_by = Keyword.fetch!(opts, :set_by)

    with :ok <- validate_source_workspace(source_uri, ws) do
      %__MODULE__{}
      |> cast(%{id: id(owner, ws, flavor), owner_uri: owner, workspace_uri: ws,
                flavor: flavor, source_uri: source_uri, set_by: set_by},
              [:id, :owner_uri, :workspace_uri, :flavor, :source_uri, :set_by])
      |> validate_required([:id, :owner_uri, :workspace_uri, :flavor, :source_uri, :set_by])
      |> Repo.insert(on_conflict: {:replace, [:source_uri, :set_by, :updated_at]},
                     conflict_target: :id)
    end
  end

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
    case Ezagent.URI.new(source_uri) do
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
  use Ezagent.DataCase, async: false
  alias Ezagent.Credential.{Adopt, UserDefaultSource}

  test "adopts a single unambiguous existing source as the user default" do
    # given exactly one cc agent owned by alice in team-a carrying credentials:
    candidates = ["entity://team-a/agent/alice-base"]
    assert {:ok, "entity://team-a/agent/alice-base"} =
             Adopt.adopt("entity://team-a/user/alice", "team-a", "cc", candidates)
    assert UserDefaultSource.resolve("entity://team-a/user/alice", "team-a", "cc") ==
             "entity://team-a/agent/alice-base"
  end

  test "REFUSES when multiple candidates are ambiguous (no silent guess)" do
    candidates = ["entity://team-a/agent/a1", "entity://team-a/agent/a2"]
    assert {:error, {:ambiguous, ^candidates}} =
             Adopt.adopt("entity://team-a/user/alice", "team-a", "cc", candidates)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test apps/ezagent_core/test/ezagent/credential/adopt_test.exs`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Ezagent.Credential.Adopt`**

```elixir
defmodule Ezagent.Credential.Adopt do
  @moduledoc "One-time migration: adopt an existing per-agent credential as a user's default source (§5.2). Refuses ambiguity rather than guessing."
  alias Ezagent.Credential.UserDefaultSource

  @spec adopt(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def adopt(owner, ws, flavor, candidates) do
    case candidates do
      [single] ->
        with {:ok, _} <- UserDefaultSource.set(owner, ws, flavor, single, set_by: owner) do
          {:ok, single}
        end
      [] -> {:error, :no_candidate}
      many -> {:error, {:ambiguous, many}}
    end
  end
end
```

The Mix task `ezagent.credential.adopt` discovers candidates (existing agents owned by `owner` in `ws` with `flavor` that have credentials) and calls `adopt/4`, printing the `:ambiguous` list for the operator to resolve with an explicit `--source`. (Candidate discovery: reuse the agent listing already used by `mix ezagent` user/agent tasks; keep the task thin.)

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

  test "grant store, user-source registry, grant principal, adapter split all present" do
    assert Code.ensure_loaded?(Ezagent.Credential.GrantRow)
    assert Code.ensure_loaded?(Ezagent.Credential.UserDefaultSource)
    assert function_exported?(Ezagent.SystemPrincipal, :credential_grant_uri, 1)
    assert function_exported?(EzagentPluginCc.Template.CcAgent, :secret_relpaths, 0)
    # secret/config disjoint per flavor (H4 invariant)
    assert "config.toml" not in EzagentPluginCodex.Template.CodexAgent.secret_relpaths()
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

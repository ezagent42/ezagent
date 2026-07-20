# cc-custom Configurable Completion Backends — Build Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the DeepSeek-specific cc flavors with one provider-configurable `cc-custom` / `cc-headless-custom` facility backed by a closed server-owned provider-profile catalog, proving DeepSeek and Kimi through the real cc path.

**Architecture:** Approved design `docs/superpowers/specs/2026-07-17-cc-custom-backends-design.md` (Approach 1). Vendor selection rides template data `"provider"` (a catalog profile NAME, validated fail-closed); the catalog (plugin code) owns base URLs, model tiers, and the server-side env-var NAME; the operator supplies the key VALUE via process env. No new Kind/Behavior; thin template-class shims satisfy the 1:1 flavor↔template-class registry.

**Tech Stack:** Elixir/OTP umbrella (`apps/ezagent_plugin_cc` + minimal domain touches), ExUnit, Req (HTTP probes), erlexec (OS processes), claude CLI 2.1.212 (live proof).

## Global Constraints

- Branch: `feat/cc-custom-backends` (worktree `.worktrees/cc-custom-backends`), rebased on `origin/main`; every PR merges into the task branch, never `main`.
- Design spec §2 facts are locked: DeepSeek block 8 vars incl. `deepseek-v4-pro[1m]`; Kimi block 9 vars incl. `ENABLE_TOOL_SEARCH=false`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1048576`.
- Locked decisions (handoff §2): no runtime forks; role × flavor only; secrets never enter template data/snapshots/logs/config dirs; credential source = deploy env via allowlisted server-side reference; fail closed with distinguishable errors; do not touch AgentRuntime ARB / EntityCaps / Git Provider / Kanban.
- **No back-compat shims** (`feedback_let_it_crash_no_workarounds`): old flavors are deleted in Task 6, not aliased.
- Every PR: TDD (red test first), `mix format` touched files, all focused tests green, then the full gate set from spec §6 before the PR lands on the task branch.
- Error atoms (new contract, replaces `:deepseek_api_key_missing`):
  `{:backend_api_key_missing, profile}` / `{:backend_api_key_missing, profile, uri}` / `:missing_backend_profile` / `{:unknown_backend_profile, name}`.
- Secrets discipline: tests use dummy keys (`sk-test-dummy-*`); real keys exist ONLY in the operator's env file (Task 7), never in the repo.

---

### Task 1 (PR-1): `ProviderCatalog` + `Provider` generalization

**Files:**
- Create: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/provider_catalog.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/provider.ex` (full refactor)
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_deepseek_agent.ex:128` (call-site to 2-arity `ensure_api_key`)
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_deepseek_agent.ex:98` (same)
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex:585-586` (generalize atom)
- Test: `apps/ezagent_plugin_cc/test/ezagent/plugin_cc/provider_catalog_test.exs` (new)
- Test: `apps/ezagent_plugin_cc/test/ezagent/template/cc_deepseek_backend_test.exs` (update provider describes in place; file retitled in Task 6)

**Interfaces:**
- Produces (all later tasks rely on these exact signatures):
  - `Ezagent.PluginCc.ProviderCatalog.names() :: [String.t()]` (sorted)
  - `Ezagent.PluginCc.ProviderCatalog.fetch(name :: String.t()) :: {:ok, profile} | :error` where `profile = %{base_url: String.t(), api_key_env: String.t(), static_env: %{String.t() => String.t()}}`
  - `Provider.provider_of(map()) :: nil | String.t()` (raw value; no silent mapping)
  - `Provider.provider_env(map()) :: {:ok, %{String.t() => String.t()}} | {:error, {:unknown_backend_profile, String.t()}} | {:error, {:backend_api_key_missing, String.t()}}`
  - `Provider.profile_env(String.t()) :: same as provider_env`
  - `Provider.ensure_api_key(String.t(), URI.t()) :: :ok | {:error, {:backend_api_key_missing, String.t(), URI.t()}}`
  - `Provider.credential_status(String.t() | nil) :: %{status: atom(), detail: String.t() | nil, expires_at: nil}` (`nil`/unknown → `:unknown`)
  - `Provider.bridge_topic_env(map(), URI.t()) :: %{String.t() => String.t()}` (unchanged behavior, condition generalized)

- [ ] **Step 1: failing catalog test**

`provider_catalog_test.exs`:

```elixir
defmodule Ezagent.PluginCc.ProviderCatalogTest do
  use ExUnit.Case, async: true
  alias Ezagent.PluginCc.ProviderCatalog

  test "names/0 is the closed sorted set" do
    assert ProviderCatalog.names() == ["deepseek", "kimi"]
  end

  test "fetch/1 returns the documented DeepSeek profile (design §2.1)" do
    assert {:ok, p} = ProviderCatalog.fetch("deepseek")
    assert p.base_url == "https://api.deepseek.com/anthropic"
    assert p.api_key_env == "DEEPSEEK_API_KEY"
    assert p.static_env == %{
             "ANTHROPIC_MODEL" => "deepseek-v4-pro[1m]",
             "ANTHROPIC_DEFAULT_OPUS_MODEL" => "deepseek-v4-pro[1m]",
             "ANTHROPIC_DEFAULT_SONNET_MODEL" => "deepseek-v4-pro[1m]",
             "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "deepseek-v4-flash",
             "CLAUDE_CODE_SUBAGENT_MODEL" => "deepseek-v4-flash",
             "CLAUDE_CODE_EFFORT_LEVEL" => "max"
           }
  end

  test "fetch/1 returns the documented Kimi profile (design §2.2)" do
    assert {:ok, p} = ProviderCatalog.fetch("kimi")
    assert p.base_url == "https://api.moonshot.ai/anthropic"
    assert p.api_key_env == "MOONSHOT_API_KEY"
    assert p.static_env == %{
             "ANTHROPIC_MODEL" => "kimi-k3",
             "ANTHROPIC_DEFAULT_OPUS_MODEL" => "kimi-k3",
             "ANTHROPIC_DEFAULT_SONNET_MODEL" => "kimi-k3",
             "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "kimi-k3",
             "CLAUDE_CODE_SUBAGENT_MODEL" => "kimi-k3",
             "ENABLE_TOOL_SEARCH" => "false",
             "CLAUDE_CODE_AUTO_COMPACT_WINDOW" => "1048576"
           }
  end

  test "fetch/1 rejects unknown and non-string names (closed catalog)" do
    assert ProviderCatalog.fetch("openai") == :error
    assert ProviderCatalog.fetch(:deepseek) == :error
    assert ProviderCatalog.fetch(nil) == :error
  end

  test "server-side env-var names live ONLY in the catalog (secret-reference allowlist)" do
    lib = Path.expand("../../lib", __DIR__)

    offenders =
      Path.wildcard(Path.join(lib, "**/*.ex"))
      |> Enum.reject(&String.ends_with?(&1, "provider_catalog.ex"))
      |> Enum.filter(fn f ->
        src = File.read!(f)
        String.contains?(src, "DEEPSEEK_API_KEY") or String.contains?(src, "MOONSHOT_API_KEY")
      end)

    assert offenders == []
  end
end
```

Run: `mix test apps/ezagent_plugin_cc/test/ezagent/plugin_cc/provider_catalog_test.exs` → FAIL (module missing).

- [ ] **Step 2: implement `provider_catalog.ex`**

```elixir
defmodule Ezagent.PluginCc.ProviderCatalog do
  @moduledoc """
  Closed, server-owned provider-profile catalog for the cc completion-backend
  dimension (design 2026-07-17 §4.1).

  A profile is DATA: the vendor's documented Claude Code env block minus the
  secret, plus the NAME of the server-side env var the deploy sets. Template
  data may only NAME a profile (`"provider" => "deepseek"`); it can never
  name an env var, URL, or model — the closed catalog is the allowlist
  (locked decision #7). Adding a vendor = adding one entry here + tests; no
  new module/flavor.

  Values track the vendors' current Claude Code guides (design §2, accessed
  2026-07-17). A deploy may retarget endpoint/model tiers without a code
  change via:

      config :ezagent_plugin_cc, :provider_profile_overrides, %{
        "deepseek" => %{base_url: "...", static_env: %{"ANTHROPIC_MODEL" => "..."}}
      }
  """

  @profiles %{
    "deepseek" => %{
      base_url: "https://api.deepseek.com/anthropic",
      api_key_env: "DEEPSEEK_API_KEY",
      static_env: %{
        "ANTHROPIC_MODEL" => "deepseek-v4-pro[1m]",
        "ANTHROPIC_DEFAULT_OPUS_MODEL" => "deepseek-v4-pro[1m]",
        "ANTHROPIC_DEFAULT_SONNET_MODEL" => "deepseek-v4-pro[1m]",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "deepseek-v4-flash",
        "CLAUDE_CODE_SUBAGENT_MODEL" => "deepseek-v4-flash",
        "CLAUDE_CODE_EFFORT_LEVEL" => "max"
      }
    },
    "kimi" => %{
      base_url: "https://api.moonshot.ai/anthropic",
      api_key_env: "MOONSHOT_API_KEY",
      static_env: %{
        "ANTHROPIC_MODEL" => "kimi-k3",
        "ANTHROPIC_DEFAULT_OPUS_MODEL" => "kimi-k3",
        "ANTHROPIC_DEFAULT_SONNET_MODEL" => "kimi-k3",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "kimi-k3",
        "CLAUDE_CODE_SUBAGENT_MODEL" => "kimi-k3",
        "ENABLE_TOOL_SEARCH" => "false",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW" => "1048576"
      }
    }
  }

  @type profile :: %{
          base_url: String.t(),
          api_key_env: String.t(),
          static_env: %{String.t() => String.t()}
        }

  @doc "The closed set of profile names, sorted."
  @spec names() :: [String.t()]
  def names, do: @profiles |> Map.keys() |> Enum.sort()

  @doc "`{:ok, profile}` for a catalog name (with deploy overrides applied), else `:error`."
  @spec fetch(term()) :: {:ok, profile()} | :error
  def fetch(name) when is_binary(name) do
    with {:ok, profile} <- Map.fetch(@profiles, name) do
      {:ok, apply_overrides(name, profile)}
    end
  end

  def fetch(_), do: :error

  @doc "True iff `name` is in the closed catalog."
  @spec known?(term()) :: boolean()
  def known?(name), do: match?({:ok, _}, fetch(name))

  defp apply_overrides(name, profile) do
    overrides = Application.get_env(:ezagent_plugin_cc, :provider_profile_overrides, %{})

    case Map.get(overrides, name) do
      nil -> profile
      ov when is_map(ov) -> Map.merge(profile, ov)
    end
  end
end
```

Run the test → PASS.

- [ ] **Step 3: failing Provider contract tests**

In `cc_deepseek_backend_test.exs`, replace the two `Provider` describes with (keep every other describe untouched for now):

```elixir
  describe "Provider.profile_env/1 + provider_env/1" do
    test "deepseek profile assembles the documented 8-var block, token from its env var" do
      with_key()
      assert {:ok, env} = Provider.profile_env("deepseek")
      assert env == %{
               "ANTHROPIC_BASE_URL" => "https://api.deepseek.com/anthropic",
               "ANTHROPIC_AUTH_TOKEN" => @key,
               "ANTHROPIC_MODEL" => "deepseek-v4-pro[1m]",
               "ANTHROPIC_DEFAULT_OPUS_MODEL" => "deepseek-v4-pro[1m]",
               "ANTHROPIC_DEFAULT_SONNET_MODEL" => "deepseek-v4-pro[1m]",
               "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "deepseek-v4-flash",
               "CLAUDE_CODE_SUBAGENT_MODEL" => "deepseek-v4-flash",
               "CLAUDE_CODE_EFFORT_LEVEL" => "max"
             }
    end

    test "kimi profile assembles the documented 9-var block" do
      System.put_env("MOONSHOT_API_KEY", "sk-kimi-test-xyz")
      on_exit(fn -> System.delete_env("MOONSHOT_API_KEY") end)

      assert {:ok, env} = Provider.profile_env("kimi")
      assert map_size(env) == 9
      assert env["ANTHROPIC_BASE_URL"] == "https://api.moonshot.ai/anthropic"
      assert env["ANTHROPIC_AUTH_TOKEN"] == "sk-kimi-test-xyz"
      assert env["ANTHROPIC_MODEL"] == "kimi-k3"
      assert env["ENABLE_TOOL_SEARCH"] == "false"
      assert env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "1048576"
    end

    test "missing key → {:error, {:backend_api_key_missing, profile}}" do
      without_key()
      assert Provider.profile_env("deepseek") == {:error, {:backend_api_key_missing, "deepseek"}}
    end

    test "unknown profile → {:error, {:unknown_backend_profile, name}} (fail closed)" do
      assert Provider.profile_env("bogus") == {:error, {:unknown_backend_profile, "bogus"}}
    end

    test "provider_env/1: no key → {:ok, %{}}; explicit anthropic → {:ok, %{}}" do
      with_key()
      assert Provider.provider_env(%{}) == {:ok, %{}}
      assert Provider.provider_env(%{"provider" => "anthropic"}) == {:ok, %{}}
    end

    test "provider_env/1: known profile → block; unknown → fail closed (NEVER silent anthropic)" do
      with_key()
      assert {:ok, env} = Provider.provider_env(%{"provider" => "deepseek"})
      assert env["ANTHROPIC_AUTH_TOKEN"] == @key
      assert {:error, {:unknown_backend_profile, "bogus"}} =
               Provider.provider_env(%{"provider" => "bogus"})
    end

    test "ensure_api_key/2 gates on the profile's own env var" do
      without_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_x")
      assert {:error, {:backend_api_key_missing, "deepseek", ^uri}} =
               Provider.ensure_api_key("deepseek", uri)

      with_key()
      assert Provider.ensure_api_key("deepseek", uri) == :ok
    end

    test "credential_status/1 is per-profile; nil/unknown → :unknown (never an alarm)" do
      with_key()
      assert %{status: :authenticated} = Provider.credential_status("deepseek")
      without_key()
      assert %{status: :missing, detail: detail} = Provider.credential_status("deepseek")
      assert detail =~ "DEEPSEEK_API_KEY"
      assert %{status: :unknown} = Provider.credential_status(nil)
      assert %{status: :unknown} = Provider.credential_status("bogus")
    end
  end
```

Also update the setup block: `@key "sk-deepseek-test-abc123"` stays; `with_key/without_key` stay (they manipulate `DEEPSEEK_API_KEY`). The old `deepseek_env/0`-specific tests are replaced by the above. Update the two instantiate fail-fast tests' expected error:

```elixir
      assert {:error, {:backend_api_key_missing, "deepseek", %URI{}}} =
               CcDeepseekAgent.instantiate("cc_deepseek.agent", tmpl, workspace_uri())
```

(and the headless twin). Update the credential-status tests to call `Provider.credential_status("deepseek")` semantics via the shims (shims pass `"deepseek"` — see Step 4).

Run → FAIL (Provider still hard-coded).

- [ ] **Step 4: refactor `provider.ex`**

Replace the whole module with:

```elixir
defmodule Ezagent.PluginCc.Provider do
  @moduledoc """
  Runtime facade for the cc completion-backend dimension — ORTHOGONAL to
  transport (pty vs headless). All vendor data lives in
  `Ezagent.PluginCc.ProviderCatalog` (closed, server-owned); this module
  resolves the profile selected by template data, injects the deploy-provided
  key from the profile's allowlisted env var, and reports credential status.

  Template data contract: `"provider"` is ABSENT or `"anthropic"` for the
  default cc path (zero extra env, byte-unchanged), or a catalog profile name
  for a custom backend. Unknown names fail CLOSED
  (`{:unknown_backend_profile, _}`) — they never silently degrade to the
  anthropic path (locked decision #9).

  The key is read via `System.get_env(profile.api_key_env)` at launch-build
  time only and lands solely in the child process env — never in template
  data, snapshots, logs, telemetry, or status detail strings (locked #6).
  """

  alias Ezagent.PluginCc.ProviderCatalog

  @provider_key "provider"
  @anthropic "anthropic"

  @spec anthropic() :: String.t()
  def anthropic, do: @anthropic

  @spec provider_key() :: String.t()
  def provider_key, do: @provider_key

  @doc """
  The raw `"provider"` template-data value: `nil` when absent, else the
  string (atom input `"anthropic"`/profile names normalized to strings).
  No validation here — validation is `profile_env/1`'s job (fail closed).
  """
  @spec provider_of(map()) :: String.t() | nil
  def provider_of(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, @provider_key) || Map.get(tmpl, :provider) do
      nil -> nil
      p when is_atom(p) -> Atom.to_string(p)
      p when is_binary(p) -> p
      _ -> nil
    end
  end

  def provider_of(_), do: nil

  @doc """
  The launch-time env map to MERGE into the claude launch env for `tmpl`.

    * no provider / explicit anthropic → `{:ok, %{}}` (default cc path
      byte-unchanged — no vendor vars ever leak in);
    * catalog profile → the profile's static block + `ANTHROPIC_BASE_URL` +
      `ANTHROPIC_AUTH_TOKEN` (read from the profile's allowlisted env var);
      key unset/empty → `{:error, {:backend_api_key_missing, name}}`;
    * unknown profile → `{:error, {:unknown_backend_profile, name}}`.
  """
  @spec provider_env(map()) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error, {:unknown_backend_profile, String.t()}}
          | {:error, {:backend_api_key_missing, String.t()}}
  def provider_env(tmpl) when is_map(tmpl) do
    case provider_of(tmpl) do
      nil -> {:ok, %{}}
      @anthropic -> {:ok, %{}}
      name -> profile_env(name)
    end
  end

  @doc "Assemble a named profile's full env block (see `provider_env/1`)."
  @spec profile_env(String.t()) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error, {:unknown_backend_profile, String.t()}}
          | {:error, {:backend_api_key_missing, String.t()}}
  def profile_env(name) when is_binary(name) do
    with {:ok, profile} <- ProviderCatalog.fetch(name),
         {:ok, token} <- api_key(profile) do
      {:ok,
       Map.merge(profile.static_env, %{
         "ANTHROPIC_BASE_URL" => profile.base_url,
         "ANTHROPIC_AUTH_TOKEN" => token
       })}
    else
      :error -> {:error, {:unknown_backend_profile, name}}
      {:error, :missing_key} -> {:error, {:backend_api_key_missing, name}}
    end
  end

  @doc """
  PTY-only bridge-topic env for a custom-backend agent — the esr-bridge
  sidecar joins `agent_bridge:<flavor>:<uri>`; empty for the default
  anthropic path (the sidecar default is already correct) and for headless
  (in-process, no WS topic). Vendor-neutral: keys off the template's
  `"flavor"`, gated on a non-anthropic provider.
  """
  @spec bridge_topic_env(map(), URI.t()) :: %{optional(String.t()) => String.t()}
  def bridge_topic_env(tmpl, %URI{} = agent_uri) when is_map(tmpl) do
    with p when is_binary(p) <- provider_of(tmpl),
         true <- p != @anthropic,
         flavor when is_binary(flavor) and flavor != "" <-
           Map.get(tmpl, "flavor") || Map.get(tmpl, :flavor) do
      %{"EZAGENT_BRIDGE_TOPIC" => "agent_bridge:#{flavor}:#{Ezagent.URI.stable_key(agent_uri)}"}
    else
      _ -> %{}
    end
  end

  @doc """
  Fail-fast launchability gate: `:ok` iff the profile's env var is set,
  else `{:error, {:backend_api_key_missing, name, uri}}`. Checked at the top
  of a custom-backend `instantiate/3` BEFORE any Kind spawn / transport-join
  wait.
  """
  @spec ensure_api_key(String.t(), URI.t()) ::
          :ok | {:error, {:backend_api_key_missing, String.t(), URI.t()}}
  def ensure_api_key(name, %URI{} = agent_uri) when is_binary(name) do
    case ProviderCatalog.fetch(name) do
      {:ok, profile} ->
        if api_key_present?(profile),
          do: :ok,
          else: {:error, {:backend_api_key_missing, name, agent_uri}}

      :error ->
        {:error, {:unknown_backend_profile, name, agent_uri}}
    end
  end

  @doc """
  Per-profile credential status (the #160 normalized enum), env-backed:
  key set → `:authenticated`; unset → `:missing` with an operator-facing
  detail naming the ENV VAR (never the value); nil/unknown profile →
  `:unknown` (never an alarm). Read-only, no network, no activation.
  """
  @spec credential_status(String.t() | nil) ::
          %{status: atom(), detail: String.t() | nil, expires_at: nil}
  def credential_status(name) when is_binary(name) do
    case ProviderCatalog.fetch(name) do
      {:ok, profile} ->
        if api_key_present?(profile) do
          %{status: :authenticated, detail: nil, expires_at: nil}
        else
          %{
            status: :missing,
            detail:
              "#{profile.api_key_env} not set — the \"#{name}\" backend has no " <>
                "credential; set #{profile.api_key_env} in the deploy env.",
            expires_at: nil
          }
        end

      :error ->
        %{status: :unknown, detail: nil, expires_at: nil}
    end
  end

  def credential_status(_), do: %{status: :unknown, detail: nil, expires_at: nil}

  # --- internals -----------------------------------------------------------

  defp api_key(%{api_key_env: env}) do
    case System.get_env(env) do
      k when is_binary(k) and k != "" -> {:ok, k}
      _ -> {:error, :missing_key}
    end
  end

  defp api_key_present?(profile), do: match?({:ok, _}, api_key(profile))
end
```

Note the deepseek shims call `Provider.ensure_api_key(agent_uri)` (1-arity) and `Provider.credential_status()` (0-arity) and `Provider.deepseek()` — update them now (they are deleted in Task 6 but must stay green until then):

- `cc_deepseek_agent.ex:128`: `:ok <- Provider.ensure_api_key(agent_uri)` → `:ok <- Provider.ensure_api_key(ProviderCatalog.fetch... ` — no: `:ok <- Provider.ensure_api_key("deepseek", agent_uri)`. Add `alias Ezagent.PluginCc.Provider` already present; use the literal `"deepseek"` (the shim IS the deepseek flavor).
- `cc_deepseek_agent.ex:82`: `Provider.credential_status()` → `Provider.credential_status("deepseek")`.
- `cc_headless_deepseek_agent.ex:98,59`: same two edits.
- Remove from the shims any use of `Provider.deepseek()/0` in `template_data_extra` — keep the function? `Provider.deepseek/0` and `Provider.api_key_env/0` are deleted in the refactor (no remaining callers after the shim edits — grep to confirm; `template_data_extra` in the shims does `Map.put(Provider.provider_key(), Provider.deepseek())` → change to `Map.put(Provider.provider_key(), "deepseek")`).

- [ ] **Step 5: generalize the spawn-skip atom (domain_session)**

`definition_agents.ex:585-586` — replace both clauses and update the comment above them (`:580-584`) to name the new contract:

```elixir
  # NARROW by design: only a KNOWN missing-credential spawn reason reclassifies
  # to a skip. Every other spawn failure stays a hard error (a bug, not the
  # environment — §"Skip vs fail"). Env-var-credential flavors (cc-custom
  # profiles; cc-deepseek until its retirement) fail this way; file-credential
  # flavors are already pre-skipped by `CredentialPrecondition.check_source/3`.
  defp credential_missing_spawn_reason?({:backend_api_key_missing, _, _}), do: true
  defp credential_missing_spawn_reason?({:backend_api_key_missing, _}), do: true
  defp credential_missing_spawn_reason?(_), do: false
```

Update its tests in `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs` (any assertion matching `:deepseek_api_key_missing` → the new tuple; grep the file for `deepseek` and update each hit consistently).

- [ ] **Step 6: run focused suites + gates**

```bash
mix test apps/ezagent_plugin_cc/test/ezagent/plugin_cc/provider_catalog_test.exs
mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_deepseek_backend_test.exs
mix test apps/ezagent_plugin_cc/test/integration/cc_config_home_credentials_test.exs
mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
mix format --check-formatted
```

All green. Then the spec §6 gate set (`mix ezagent.arch.scan && mix ezagent.doc.scan && mix ezagent.uri_query.scan && mix ezagent.check_invariants`).

- [ ] **Step 7: commit**

`feat(cc-custom): add closed provider-profile catalog + generalize Provider facade (PR-1)`

---

### Task 2 (PR-2): `cc-custom` flavor (PTY transport)

**Files:**
- Create: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_custom_agent.ex`
- Create: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/cc_custom_bridge_adapter.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex` (register class + flavor)
- Test: `apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs` (new)

**Interfaces:**
- Consumes: Task 1's `Provider.*` / `ProviderCatalog.*`; `CcAgent.instantiate_for_flavor/4`, `CcAgent.validate_after_class/1`, `Ezagent.Kind.Template.content_field/2`.
- Produces: flavor `"cc-custom"` → `{Ezagent.Entity.Agent, Ezagent.PluginCc.Template.CcCustomAgent}` + adapter `EzagentPluginCc.CcCustomBridgeAdapter`; template class name `"cc_custom.agent"`.

- [ ] **Step 1: failing tests** — create `cc_custom_backend_test.exs` with setup copied from the deepseek suite (same `@key`, `with_key/without_key`, mock-claude PTY setup block) and:

```elixir
  describe "registration" do
    test "agent_flavors/0 declares cc-custom → CcCustomAgent + adapter" do
      by = Map.new(EzagentPluginCc.Application.agent_flavors(), &{&1.flavor, &1})
      assert %{kind: Ezagent.Entity.Agent, template_class: CcCustomAgent} = by["cc-custom"]
      assert {:ok, %{template_class: CcCustomAgent}} =
               Ezagent.AgentFlavorRegistry.lookup("cc-custom")
      assert {:ok, EzagentPluginCc.CcCustomBridgeAdapter} =
               Ezagent.AgentBridge.AdapterRegistry.lookup("cc-custom")
    end

    test "template metadata: class name + cc config_dir namespace" do
      assert CcCustomAgent.template_name() == "cc_custom.agent"
      assert CcCustomAgent.config_dir_namespace() == CcAgent.config_dir_namespace()
    end
  end

  describe "validate/1 — fail-closed profile contract" do
    @base %{
      "class" => "cc_custom.agent",
      "agent_uri" => "entity://team-alpha/agent/cc_cu-valid",
      "cwd" => "/tmp"
    }

    test "accepts a catalog profile" do
      assert CcCustomAgent.validate(Map.put(@base, "provider", "deepseek")) == :ok
      assert CcCustomAgent.validate(Map.put(@base, "provider", "kimi")) == :ok
    end

    test "missing provider → :missing_backend_profile" do
      assert CcCustomAgent.validate(@base) == {:error, :missing_backend_profile}
    end

    test "unknown provider → {:unknown_backend_profile, name} (anthropic is NOT a profile)" do
      assert {:error, {:unknown_backend_profile, "bogus"}} =
               CcCustomAgent.validate(Map.put(@base, "provider", "bogus"))

      assert {:error, {:unknown_backend_profile, "anthropic"}} =
               CcCustomAgent.validate(Map.put(@base, "provider", "anthropic"))
    end

    test "rejects the wrong class" do
      tmpl = Map.put(@base, "provider", "deepseek")
      assert {:error, {:wrong_class, "cc.agent"}} =
               CcCustomAgent.validate(%{tmpl | "class" => "cc.agent"})
    end
  end

  describe "template_data_extra/1" do
    test "passes the content provider through (curl-pattern content seam)" do
      data = CcCustomAgent.template_data_extra(%{provider: "kimi", model: "x"})
      assert data["provider"] == "kimi"
      assert data["model"] == "x"
    end

    test "no provider in content → key absent (validate fails it later, fail closed)" do
      refute Map.has_key?(CcCustomAgent.template_data_extra(%{model: "x"}), "provider")
    end
  end

  describe "credential adapter" do
    test "no on-disk credential, no host login" do
      assert CcCustomAgent.credential_relpaths() == []
      assert CcCustomAgent.secret_relpaths() == []
      assert CcCustomAgent.host_login_dir() == nil
      assert Ezagent.Agent.CredentialAdapter.host_login_source_dir(CcCustomAgent) == :none
    end

    test "credential_status/2 is profile-driven via opts" do
      with_key()
      assert %{status: :authenticated} =
               CcCustomAgent.credential_status(nil, backend_profile: "deepseek")

      without_key()
      assert %{status: :missing} = CcCustomAgent.credential_status(nil, backend_profile: "deepseek")
      assert %{status: :unknown} = CcCustomAgent.credential_status(nil, [])
    end
  end

  describe "instantiate/3" do
    test "missing key → {:backend_api_key_missing, profile, uri} before any spawn" do
      without_key()
      tmpl = %{
        "class" => "cc_custom.agent",
        "agent_uri" => "entity://team-alpha/agent/cc_cu-missing",
        "cwd" => "/tmp",
        "provider" => "deepseek"
      }

      assert {:error, {:backend_api_key_missing, "deepseek", %URI{}}} =
               CcCustomAgent.instantiate("cc_custom.agent", tmpl, workspace_uri())
    end
  end

  describe "cold restart" do
    test "respawn flavor + persisted profile re-resolve (both resolver paths)" do
      sandbox = %{
        respawn_template_data: %{
          "flavor" => "cc-custom",
          "provider" => "kimi",
          "class" => "cc_custom.agent",
          "cwd" => "/tmp"
        }
      }

      assert {:ok, "cc-custom"} = Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(sandbox)

      assert {:ok, "cc-custom"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(%{
                 respawn_template_data: %{"class" => "cc_custom.agent", "cwd" => "/tmp"}
               })
    end
  end

  describe "pty launch env (build_claude_cmd/3)" do
    # same mock-claude setup block as the deepseek suite (copy verbatim)
    test "deepseek profile injects its block + the cc-custom bridge topic" do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_cu-pty")

      tmpl = %{
        "class" => "cc_custom.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => ctx.cwd,
        "agent_config_dir" => ctx.config_dir,
        "provider" => "deepseek",
        "flavor" => "cc-custom"
      }

      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(uri, ctx.cwd, tmpl)
      assert cmd_env["ANTHROPIC_AUTH_TOKEN"] == @key
      assert cmd_env["ANTHROPIC_BASE_URL"] == "https://api.deepseek.com/anthropic"
      assert cmd_env["EZAGENT_BRIDGE_TOPIC"] ==
               "agent_bridge:cc-custom:" <> Ezagent.URI.stable_key(uri)
    end

    test "kimi profile injects its 9-var block (MOONSHOT_API_KEY)" do
      System.put_env("MOONSHOT_API_KEY", "sk-kimi-test-xyz")
      on_exit(fn -> System.delete_env("MOONSHOT_API_KEY") end)
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_cu-kimi")

      tmpl = %{
        "class" => "cc_custom.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => ctx.cwd,
        "agent_config_dir" => ctx.config_dir,
        "provider" => "kimi",
        "flavor" => "cc-custom"
      }

      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(uri, ctx.cwd, tmpl)
      assert map_size(Map.take(cmd_env, ~w(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
             ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
             ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL ENABLE_TOOL_SEARCH
             CLAUDE_CODE_AUTO_COMPACT_WINDOW))) == 9
      assert cmd_env["ANTHROPIC_MODEL"] == "kimi-k3"
    end

    @catalog_keys ~w(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
                     ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
                     ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL
                     CLAUDE_CODE_EFFORT_LEVEL ENABLE_TOOL_SEARCH
                     CLAUDE_CODE_AUTO_COMPACT_WINDOW)

    test "default anthropic cc path UNCHANGED (no catalog var leaks)", ctx do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_plain-pty2")

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => ctx.cwd,
        "agent_config_dir" => ctx.config_dir
      }

      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(uri, ctx.cwd, tmpl)

      for k <- @catalog_keys, do: refute(Map.has_key?(cmd_env, k), "leaked #{k} into cc path")
      refute Map.has_key?(cmd_env, "EZAGENT_BRIDGE_TOPIC")
    end
  end

  describe "bridge adapter" do
    test "serves cc-custom over the shared subprocess_ws socket" do
      alias EzagentPluginCc.CcCustomBridgeAdapter
      assert CcCustomBridgeAdapter.flavor() == "cc-custom"
      assert CcCustomBridgeAdapter.transport_class() == :subprocess_ws
      assert CcCustomBridgeAdapter.socket_path() == "/agent_bridge"
      assert CcCustomBridgeAdapter.channel_topic_prefix() == "agent_bridge:cc-custom:"
    end
  end
```

(`workspace_uri/0` helper as in the deepseek suite.) Run → FAIL (modules missing).

- [ ] **Step 2: implement `cc_custom_agent.ex`**

Take `cc_deepseek_agent.ex` as the structural base with these exact changes:
`@flavor "cc-custom"`; `template_name → "cc_custom.agent"`; `check_class` accepts `"cc_custom.agent"`; **delete every provider injection** and add:

```elixir
  alias Ezagent.PluginCc.{Provider, ProviderCatalog}

  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    base = CcAgent.template_data_extra(content)

    case Ezagent.Kind.Template.content_field(content, :provider) do
      p when is_binary(p) and p != "" -> Map.put(base, Provider.provider_key(), p)
      _ -> base
    end
  end

  def template_data_extra(_), do: %{}

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_provider(tmpl),
         :ok <- CcAgent.validate_after_class(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_provider(tmpl) do
    case Map.get(tmpl, Provider.provider_key()) do
      nil -> {:error, :missing_backend_profile}
      name when is_binary(name) ->
        if ProviderCatalog.known?(name),
          do: :ok,
          else: {:error, {:unknown_backend_profile, name}}

      bad -> {:error, {:unknown_backend_profile, bad}}
    end
  end

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    with {:ok, agent_uri} <- parse_uri(uri_str),
         :ok <- check_provider(tmpl),
         :ok <- Provider.ensure_api_key(Map.fetch!(tmpl, Provider.provider_key()), agent_uri) do
      tmpl = Map.put(tmpl, "flavor", @flavor)
      CcAgent.instantiate_for_flavor(__MODULE__, uri_str, tmpl, workspace_uri)
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}
```

CredentialAdapter block (replaces the deepseek shim's):

```elixir
  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: CcAgent.credential_env_var()

  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals, do: CcAgent.auth_failure_signals()

  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(_home, opts \\ []),
    do: Provider.credential_status(Keyword.get(opts, :backend_profile))

  @impl Ezagent.Agent.CredentialAdapter
  def host_login_dir, do: nil
```

The rest delegates exactly like the deepseek shim: `config_dir_namespace → CcAgent.config_dir_namespace()`, `config_schema` delegate, `compile/2` via `compile_cc_agent_data`, `ensure_subprocess_alive/list_extensions/toggle_extension/destroy_config_dir` delegates, `parse_uri/1`, plus `Ezagent.UI.Form`:

```elixir
  @impl Ezagent.UI.Form
  def form_fields do
    CcAgent.form_fields() ++
      [
        %{
          name: "provider",
          type: :select,
          label: "Backend profile",
          required: true,
          options: Ezagent.PluginCc.ProviderCatalog.names()
        }
      ]
  end
```

(First verify `Ezagent.UI.Form` supports `:select` with `:options`; if the contract only has `:text`-style fields, fall back to `type: :text` with `placeholder: Enum.join(ProviderCatalog.names(), " | ")` — check `apps/ezagent_core/lib/ezagent/ui/form.ex` before writing.)

Moduledoc: adapt the deepseek shim's — same 1:1-flavor rationale, credential contract paragraph, but document that `"provider"` is REQUIRED user input naming a catalog profile (fail closed).

- [ ] **Step 3: implement `cc_custom_bridge_adapter.ex`** — verbatim adapt of `deepseek_bridge_adapter.ex`: `flavor() → "cc-custom"`, `channel_topic_prefix() → "agent_bridge:cc-custom:"`, everything else delegated to `EzagentPluginCc.BridgeAdapter`.

- [ ] **Step 4: register in `application.ex`** — add `Ezagent.PluginCc.Template.CcCustomAgent` to `template_classes/0`, and to `agent_flavors/0`:

```elixir
      %{
        flavor: "cc-custom",
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCc.Template.CcCustomAgent,
        bridge_adapter: EzagentPluginCc.CcCustomBridgeAdapter
      },
```

(DeepSeek decls stay until Task 6.)

- [ ] **Step 5: run focused tests + gates** (as Task 1 Step 6, plus the new file). Commit: `feat(cc-custom): add cc-custom PTY flavor with closed-profile validation (PR-2)`.

---

### Task 3 (PR-3): `cc-headless-custom` flavor + reply-route clause

**Files:**
- Create: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_custom_agent.ex`
- Create: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/cc_headless_custom_bridge_adapter.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:339-345` (add clause)
- Test: `apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs` (extend)

**Interfaces:** mirrors Task 2 on the headless transport; `CcHeadlessAgent.instantiate_for_flavor/4`, `CcHeadlessAgent.validate_after_class/1`, `sdk_sidecar_params/2` (already profile-driven via `provider_env/1`).

- [ ] **Step 1: failing tests** — extend `cc_custom_backend_test.exs`:

```elixir
  describe "cc-headless-custom" do
    test "registered with the cc-headless behavior set" do
      by = Map.new(EzagentPluginCc.Application.agent_flavors(), &{&1.flavor, &1})
      assert %{kind: Ezagent.Entity.Agent, template_class: CcHeadlessCustomAgent} =
               by["cc-headless-custom"]

      assert is_function(by["cc-headless-custom"].instance_behaviors, 0)

      assert {:ok, EzagentPluginCc.CcHeadlessCustomBridgeAdapter} =
               Ezagent.AgentBridge.AdapterRegistry.lookup("cc-headless-custom")
    end

    test "validate requires a catalog profile (same contract as pty)" do
      base = %{
        "class" => "cc_headless_custom.agent",
        "agent_uri" => "entity://team-alpha/agent/cch_cu",
        "cwd" => "/tmp"
      }

      assert CcHeadlessCustomAgent.validate(base) == {:error, :missing_backend_profile}
      assert CcHeadlessCustomAgent.validate(Map.put(base, "provider", "kimi")) == :ok
    end

    test "instantiate fail-fast on missing key" do
      without_key()

      tmpl = %{
        "class" => "cc_headless_custom.agent",
        "agent_uri" => "entity://team-alpha/agent/cch_cu-missing",
        "cwd" => "/tmp",
        "provider" => "deepseek"
      }

      assert {:error, {:backend_api_key_missing, "deepseek", %URI{}}} =
               CcHeadlessCustomAgent.instantiate("cc_headless_custom.agent", tmpl, workspace_uri())
    end

    test "headless sidecar params thread the profile block (both vendors)" do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_cu")

      params =
        CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp", "provider" => "deepseek"})

      assert map_size(params.cmd_env) == 8
      assert params.cmd_env["ANTHROPIC_AUTH_TOKEN"] == @key

      System.put_env("MOONSHOT_API_KEY", "sk-kimi-test-xyz")
      on_exit(fn -> System.delete_env("MOONSHOT_API_KEY") end)

      params2 = CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp", "provider" => "kimi"})
      assert map_size(params2.cmd_env) == 9
      assert params2.cmd_env["ANTHROPIC_BASE_URL"] == "https://api.moonshot.ai/anthropic"
    end

    test "cold restart resolves the headless custom flavor" do
      assert {:ok, "cc-headless-custom"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(%{
                 respawn_template_data: %{
                   "flavor" => "cc-headless-custom",
                   "provider" => "deepseek",
                   "class" => "cc_headless_custom.agent",
                   "cwd" => "/tmp"
                 }
               })
    end

    test "sync_result_action routes cc-headless-custom replies to :cc_headless_sync_result" do
      # the clause under test is private; assert behaviorally via the public path
      # used by Agent.Delivery — see receive.ex:339-345. If no public seam exists,
      # assert via Code.compile_string-free source check instead:
      src = File.read!(Path.expand("../../../../ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex", __DIR__))
      assert src =~ ~s|sync_result_action("cc-headless-custom"), do: :cc_headless_sync_result|
    end
  end
```

(Prefer the behavioral route if `Agent.Delivery` exposes one — check `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/delivery.ex` first; the source-grep assertion is the fallback.)

- [ ] **Step 2: implement the class + adapter** — adapt `cc_headless_deepseek_agent.ex` exactly as Task 2 adapted the pty shim (namespace → `CcHeadlessAgent.config_dir_namespace()`, delegates to `CcHeadlessAgent`, same `check_provider/1`, `credential_status/2` opts-driven, NO `UI.Form` — the headless deepseek shim has none). Adapter: `flavor() → "cc-headless-custom"`, `channel_topic_prefix() → "cc-headless-custom"`, delegates to `CcHeadlessBridgeAdapter`.

- [ ] **Step 3: register + receive.ex clause** — application.ex adds both; `receive.ex` after the `"cc-headless"` clause add:

```elixir
  # cc-custom (provider-profile) headless variant — same headless SDK sidecar,
  # same unique reply action; ONE clause serves every catalog profile.
  defp sync_result_action("cc-headless-custom"), do: :cc_headless_sync_result
```

- [ ] **Step 4: run + gates + commit** — `feat(cc-custom): add cc-headless-custom flavor + reply-route clause (PR-3)`.

---

### Task 4 (PR-4): credential routing — profile threading

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/agent/credential_precondition.ex:64-71,109-125`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex` (thread role-slot `provider` into `check_source` + spawn opts)
- Modify: `apps/ezagent_domain_agent/lib/ezagent/agent/recipe_materializer.ex:70-76` (put `provider` into content)
- Modify: `apps/ezagent_domain_agent/lib/ezagent/domain/agent.ex` `read_credential_status/3` (+ private `trusted_backend_profile/1` mirroring `trusted_config_dir/1`)
- Test: precondition + materialize + status tests (existing files, updated expectations)

**Interfaces:**
- `CredentialPrecondition.check_source(installer, workspace_uri, flavor, opts \\ [])` — `opts[:backend_profile]`.
- Role slot maps accept optional `provider: <name>` (string or atom key).
- `CcCustomAgent.credential_status(nil, backend_profile: name)` (Task 2) is the callee everywhere.

- [ ] **Step 1: failing tests**

```elixir
# credential_precondition_test (or the integration file's describe):
    test "cc-custom skips when the SELECTED profile's key is missing, proceeds when present" do
      previous = System.get_env("MOONSHOT_API_KEY")
      System.delete_env("MOONSHOT_API_KEY")
      on_exit(fn -> if previous, do: System.put_env("MOONSHOT_API_KEY", previous) end)

      installer = Ezagent.URI.user(:system, "kimi#{System.unique_integer([:positive])}")

      assert {:skip, {:credential_unavailable, "cc-custom"}} =
               CredentialPrecondition.check_source(
                 installer, Ezagent.URI.workspace(:system), "cc-custom",
                 backend_profile: "kimi"
               )

      System.put_env("MOONSHOT_API_KEY", "test-only-key")

      assert :ok =
               CredentialPrecondition.check_source(
                 installer, Ezagent.URI.workspace(:system), "cc-custom",
                 backend_profile: "kimi"
               )
    end

    test "cc-custom with NO profile context fails closed (skip, never a silent pass)" do
      installer = Ezagent.URI.user(:system, "nop#{System.unique_integer([:positive])}")

      assert {:skip, {:credential_unavailable, "cc-custom"}} =
               CredentialPrecondition.check_source(
                 installer, Ezagent.URI.workspace(:system), "cc-custom"
               )
    end

# recipe_materializer_test:
    test "template_content threads opts[:provider] into content" do
      {:ok, content} =
        RecipeMaterializer.template_content(recipe(), %{
          flavor: "cc-custom", role_name: "orchestrator",
          agent_uri: Ezagent.URI.new!("entity://team-alpha/agent/cc_x"),
          provider: "deepseek"
        })

      assert content[:provider] == "deepseek" or content["provider"] == "deepseek"
    end
```

- [ ] **Step 2: precondition** — `check_source/3` → `check_source/4` with `opts \\ []`; env branch:

```elixir
      environment_credential?(module) ->
        case module.credential_status(nil, backend_profile: opts[:backend_profile]) do
          %{status: :authenticated} -> :ok
          _ -> {:skip, {:credential_unavailable, flavor}}
        end
```

- [ ] **Step 3: definition_agents threading** — beside `flavor_of/1` (`:828-831`) add `provider_of/1` (same atom-or-string pattern, returns nil when absent); pass `backend_profile: provider_of(agent)` into the `CredentialPrecondition.check_source/3` call site (`:302`) and `provider: provider_of(agent)` into the `create_agent_from_recipe` opts (`:537-551`) only when non-nil.

- [ ] **Step 4: recipe_materializer** — in `template_content/2` (`:70-76`) add one line:

```elixir
       |> maybe_put(:provider, Map.get(opts, :provider), &is_binary/1)
```

- [ ] **Step 5: UI status path** — in `Domain.Agent.read_credential_status/3` add (mirroring `trusted_config_dir/1`'s sandbox read):

```elixir
      config_dir = trusted_config_dir(agent_uri)
      flavor = safe_flavor(agent_uri)
      opts = maybe_put_backend_profile(opts, agent_uri)
      {:ok, Ezagent.Agent.CredentialStatus.classify(agent_uri, flavor, config_dir, opts)}
```

with `trusted_backend_profile/1` reading the persisted `:sandbox` slice's `respawn_template_data["provider"]` (non-activating, same pattern as `trusted_config_dir/1`; nil when absent) and `maybe_put_backend_profile/2` doing `Keyword.put_new(opts, :backend_profile, profile)` only when profile is a non-empty binary. Add a test: persisted cc-custom agent with `provider: "kimi"` and no `MOONSHOT_API_KEY` → status `:missing`; key set → `:authenticated`.

- [ ] **Step 6: run + gates + commit** — `feat(cc-custom): thread backend profile through credential routing (PR-4)`.

---

### Task 5 (PR-5): seeds + test/CI config + collateral

**Files:**
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex:431-440` — `flavor: "cc-deepseek"` → `flavor: "cc-custom"` + add `provider: "deepseek"` to the content; update the comment block.
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:502-524` — role `flavor: "cc-custom"`, add `provider: "deepseek"` to the role map; update the #1332 comment to record THIS migration (flavor generalized in cc-custom PR; no-clobber policy unchanged).
- Modify: `config/test.exs:86-100` — after the `DEEPSEEK_API_KEY` block add the same for `MOONSHOT_API_KEY` (`"sk-test-dummy-moonshot-not-a-real-key"`), comment updated to name the cc-custom catalog.
- Modify: `.github/workflows/ci.yml:179-185` — add `MOONSHOT_API_KEY: sk-test-dummy-moonshot-not-a-real-key`.
- Modify: `.gitleaks.toml:16-19` — allowlist the moonshot dummy alongside.
- Modify: `scripts/audit_agent_skill_homes.exs:37` — `@headless_flavors ["cc-headless", "cc-headless-custom"]` (drop `-deepseek` — Task 6 deletes it).
- Tests: `cc_orchestrator_seed_flavor_test.exs` (assertions → `cc-custom`/`cc_custom.agent` + `provider: "deepseek"` in content); the domain_session reseed/installation/materialize tests listed in spec Appendix A (flavor strings).

- [ ] **Step 1: failing seed tests** — update `cc_orchestrator_seed_flavor_test.exs:5-63` expectations to `cc-custom` + `cc_custom.agent` + content `provider: "deepseek"`; update the five domain_session test files' flavor strings (each hit from spec Appendix A).
- [ ] **Step 2: apply the seed/config/collateral edits above.**
- [ ] **Step 3: run** the five test files + `mix test apps/ezagent_plugin_cc/test/ezagent/orchestrator` → green; gates; commit `feat(cc-custom): flip orchestrator seeds + test/CI config to cc-custom profiles (PR-5)`.

---

### Task 6 (PR-6): retire the deepseek flavors (no shims)

**Files:**
- Delete: `template/cc_deepseek_agent.ex`, `template/cc_headless_deepseek_agent.ex`, `plugin_cc/deepseek_bridge_adapter.ex`, `plugin_cc/cc_headless_deepseek_bridge_adapter.ex`, `test/ezagent/template/cc_deepseek_backend_test.exs`
- Modify: `application.ex` (remove the 2 classes + 2 flavor decls)
- Modify: `receive.ex` (remove the `"cc-headless-deepseek"` clause)
- Modify: `credential_adapter_completeness_test.exs:34-39` (roster → the two custom classes)
- Modify: comment sweep per spec Appendix A ("comment sweep" row)
- Possibly: `arch_baseline_manifest.exs` def-count
- Finalize: `cc_custom_backend_test.exs` — fold in any remaining deepseek-suite parity describes not already ported (spec Appendix B), now asserting against the custom classes.

- [ ] **Step 1: port remaining parity tests** into `cc_custom_backend_test.exs` (per spec Appendix B — every row of the retired suite accounted for).
- [ ] **Step 2: delete + unregister + clause removal.**
- [ ] **Step 3: grep gate** — add/run:

```bash
! grep -rn "cc-deepseek\|cc_deepseek\|cc-headless-deepseek\|cc_headless_deepseek\|deepseek_api_key_missing" \
  apps/ config/ scripts/ .github/ --include="*.ex" --include="*.exs" --include="*.yml" | grep -v test/ | grep -v "\.md"
```

(Expected: zero code references; `deepseek` as a catalog profile NAME and `DEEPSEEK_API_KEY` in the catalog + test/CI dummies remains, by design.)

- [ ] **Step 4: full suite** `mix test` + all spec §6 gates + `mix precommit`; commit `feat(cc-custom)!: retire cc-deepseek flavors in favor of cc-custom profiles (PR-6)`.

---

### Task 7 (PR-7): local live proof (lead-authorized)

**Prereq (operator, out-of-band):** keys at `~/.ezagent/default/credentials/cc-custom.env` (chmod 600, git-ignored):

```bash
DEEPSEEK_API_KEY=sk-...
MOONSHOT_API_KEY=sk-...
```

- [ ] **Step 1: CLI probes** (spec §2.4, both vendors) — record command, exit, response shape, model, duration; sanitized.
- [ ] **Step 2: product-path proof** — boot local (`EZAGENT_SIGNING_SEED_V1` per project convention; `mix ecto.migrate` fresh dev DB; source the env file before `mix phx.server`); create one `cc-custom` PTY agent (`provider: "deepseek"`) and one `cc-headless-custom` agent (`provider: "kimi"`); send each a message through the product chat path; capture sanitized transcripts (provider profile, model, transport, command/path, timestamp, outcome).
- [ ] **Step 3: negative proofs** — `provider: "bogus"` rejected at create with `{:unknown_backend_profile, _}`; keyless env (unset the var, restart) → create fails `{:backend_api_key_missing, "deepseek", _}` and the socialware orchestrator slot SKIPS (not halts) per the chain-C contract.
- [ ] **Step 4: evidence commit** — `docs/e2e/2026-07-17/cc-custom-live-proof/` (README + transcripts, zero key material — grep the dir for `sk-` before committing); return updated.

---

## Self-review log (author, 2026-07-17)

- Spec coverage: §4.1→T1, §4.2→T1, §4.3→T2/T3, §4.4→T4, §4.5→T2+T4+T5, §4.6→T3, §4.7→T1(moduledoc)+T6(grep), §4.8→no task needed, §5→T5/T6, §6→gates each task + T6 full, §10 resolutions→T1 ([1m]) + T5 (role key) + T7 (local). Appendix A rows all map to T1–T6; Appendix B → T2/T3/T6.
- Behavior-change flag: the old "unknown provider → silent anthropic" test is REPLACED in T1 Step 3 (fail closed) — deliberate, spec §4.2.
- Ordering dependency: seeds flip (T5) only after profile threading (T4) — a cc-custom orchestrator without T4 would skip in the automatic lane. Documented in T5's commit message.
- Type consistency: `{:backend_api_key_missing, name}` (2-tuple, from `profile_env/1`) vs `{:backend_api_key_missing, name, uri}` (3-tuple, from `ensure_api_key/2`) — both matched in `credential_missing_spawn_reason?` (T1 Step 5). `credential_status/1` arg is `String.t() | nil` everywhere.

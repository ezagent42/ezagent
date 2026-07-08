defmodule Ezagent.PluginCc.Template.CcAgent do
  @moduledoc """
  Unified CC agent Template Class (PR-D2, Allen 2026-05-19; mode field
  removed PR-V1-fix Allen 2026-05-21).

  Replaces the previous split between `cc.pty` and `cc.channel_instance`
  Template Classes. The operator now adds ONE template (`cc.agent`)
  per CC agent and the spawn path is always local-pty.

  The earlier PR-D2 plan reserved a `mode` field with values
  `"local-pty"` / `"remote-channel"` so a future external-bridge mode
  could share the same Template Class. Allen 2026-05-21 cut this:
  remote-channel was never wired and the placeholder + dichotomy were
  dead weight. If/when remote support returns, it will land as a
  separate plugin + Template Class, not a mode field. The `"mode"`
  field is no longer part of the schema; if a legacy row still carries
  it the template is accepted and the field ignored (no migration
  required — see PR-D2 migration that originally seeded the field).

  ## Architecture: instantiate PRODUCES the Kind (Allen 2026-05-21)

  Allen's mental model is "Template.instantiate produces a new Kind".
  Pre-V1-fix the AgentNewLive flow inverted this: it called
  `SpawnRegistry.spawn(agent_uri)` directly (which spawned the Agent
  Kind) BEFORE `Workspace.add_template/3` (which chains to
  instantiate). cc.agent.instantiate then short-circuited on the
  already-alive Kind and started PtyServer only — making it look like
  templates couldn't bring an Agent Kind up standalone.

  The V1 fix removed the pre-spawn from AgentNewLive AND made this
  template do the full job: when instantiate runs it BOTH ensures the
  Agent Kind exists (via `SpawnRegistry.spawn/1`) AND starts the
  PtyServer. After `add_template → invoke_template → instantiate`
  returns, the caller has a fully-operational cc agent.

  ## Template data

  Legacy 3-key form (still valid — backward compat):

      %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/<workspace>/cc_<name>",
        "cwd" => "/path"
      }

  Extended form (Phase 7 completion PR-1, SPEC §1.5 (c)) — the
  AgentTemplate→cc adapter (`Ezagent.Entity.AgentTemplate.to_template_data/2`)
  threads these OPTIONAL keys:

      %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/<workspace>/cc_<name>",
        "cwd" => "/path",
        "config_dir" => "/path/to/per-agent/.claude",
        "operator_settings_path" => "/path/to/operator/settings.json",
        "operator_mcp_config_path" => "/path/to/operator/mcp.json",
        "api_key_helper" => "/path/to/api-key-helper.sh"
      }

  `"config_dir"` is the UNIVERSAL, flavor-neutral per-agent config-home
  data key (Allen 2026-06-03): every flavor's `AgentTemplate` emits it; the
  cc Template Class READS it and applies claude semantics (it copies the
  dir per-agent and exports `CLAUDE_CONFIG_DIR`). It is NOT a cc-named
  `"claude_config_dir"` key. All extended keys are optional — absent ⇒ the
  legacy behavior,
  no regression. `build_claude_cmd/3` emits the operator `--settings` /
  `--mcp-config` such that the **mandatory plugin safety `--settings`
  is LAST** (claude `--settings` is last-wins, so `remoteControlAtStartup:
  false` is non-bypassable) and the trusted esr-bridge `--mcp-config` is
  never replaced (claude merges MCP configs additively — an operator
  config adds servers but cannot delete the bridge).

  ## codex HIGH-2 — argv-safe invocation

  `build_claude_cmd/3` returns an **argv list** (`[cmd | args]`), not a
  shell string. `Ezagent.Domain.Pty` runs a list-form `cmd_override`
  via `execve` with NO shell, so every operator-controlled sandbox
  path is exactly ONE `argv[]` element. An operator value containing
  a space, a literal ` --settings /tmp/x.json`, or shell
  metacharacters (`;`, `$()`, backtick, `&&`) is delivered to `claude`
  verbatim as a single argument — it cannot create an extra flag
  (which would defeat the `--settings` last-wins safety guarantee) and
  it cannot execute a shell command. The universal `config_dir` is passed
  as a structured `CLAUDE_CONFIG_DIR` env var via the Server`s `:cmd_env`
  param, never as a `VAR=val` command prefix.

  ## codex review of #233 — argv element 0 is an ABSOLUTE PATH

  The no-shell argv form has a corollary the PR-1 hardening missed:
  erlexec's list-form `:exec.run/2` runs `execve(3)` directly — no
  shell, hence no `$PATH` search. A bare `"claude"` as argv element 0
  resolves only if `claude` lives in `cwd`, so the hardening regressed
  production cc startup (the pre-#233 shell-string path did resolve
  `claude` via `$PATH`). `build_claude_cmd/3` now resolves the
  `claude` executable to an absolute path via
  `System.find_executable/1` before building the argv. When `claude`
  is not on `PATH`, `build_claude_cmd/3` returns
  `{:error, :claude_not_found}` — a clear, propagated error, NOT a
  silent fall back to the shell. `instantiate/3` therefore fails
  loudly instead of spawning a PtyServer whose child can never start.

  ## Idempotency (PR-D2 + V1 fix)

  `instantiate/3` first looks up `agent_uri` in `KindRegistry`.
  If alive, returns the existing URI — no respawn, no PTY waste.
  Otherwise spawns the Agent Kind via `SpawnRegistry.spawn_detailed/1`
  then starts the PtyServer via `Ezagent.Domain.Pty.start/2` (facade
  over the `ezagent_domain_pty` Tier-2 app). Both layers are atomically
  dedup'd: Agent Kind via `KindRegistry` (entity:// spawn fn returns
  `{:error, {:already_started, _}}` for duplicates), PtyServer via the
  Domain.Pty :via Registry (`EzagentDomainPty.Registry`).

  ## codex round-6 HIGH-1 — the `fresh?` signal

  `instantiate/3` returns the 3-element `{:ok, [agent_uri],
  %{fresh?: boolean()}}` form. `fresh?` is `true` iff THIS call's
  `DynamicSupervisor.start_child` STARTED the Agent Kind worker — the
  atomic outcome `SpawnRegistry.spawn_detailed/1` preserves. The
  idempotency short-circuit (Kind + PtyServer already alive) returns
  `fresh?: false` — the worker pre-existed.

  `update_agent_template`'s rollback-safe swap reads `fresh?` to refuse
  silently adopting a worker another process created. Deriving it from
  the atomic spawn result — rather than a pre-probe of `KindRegistry`
  before the spawn — removes a TOCTOU window: a concurrent registration
  between a pre-probe and the spawn would make an adopted worker read
  as fresh.

  ## codex round-8 HIGH-1 — a `fresh?: false` result starts NO sidecar

  Round 6/7 made `fresh?` an atomic, side-effect-aware signal at the
  Ezagent domain layer. But the Template Class itself was still not
  side-effect-free for a rejected adoption: `spawn_for_local_pty/2`
  called `ensure_agent_kind/1` and then UNCONDITIONALLY continued to
  `ensure_pty_server/3`. When `ensure_agent_kind/1` finds the Agent
  Kind `:already_started` — a worker THIS call did NOT create —
  `ensure_pty_server/3` would still start a PTY / `claude` sidecar for
  that pre-existing (possibly foreign or orphaned) worker, attaching a
  new process + config + cwd to it.

  Round 8 makes the fresh-check happen BEFORE any stateful side effect.
  When `ensure_agent_kind/1` reports `:already_started`,
  `spawn_for_local_pty/2` returns `{:ok, [agent_uri], %{fresh?: false}}`
  IMMEDIATELY — it does NOT call `ensure_pty_server/3`, does NOT start
  a sidecar. Whether to adopt a worker this call did not create is the
  caller's (the Generator's / `update_agent_template`'s) decision, not
  the Template Class's. The Template Class only ever brings up a PTY
  for a worker IT freshly started.

  ## codex round-10 HIGH-2 — the Template Class undoes its OWN partial spawn

  Round 8 stopped a `:already_started` Kind from getting a sidecar, but
  the FRESH path was still not all-or-nothing: `spawn_for_local_pty/2`
  freshly STARTED the Agent Kind, then called `ensure_pty_server/3` —
  and a PTY / `claude` startup failure there returned a bare
  `{:error, reason}` while the just-started Agent Kind stayed LIVE. As a
  Generator agent slot that is an orphan: the slot returns
  `{:error, _}` with NO worker URI, so the Generator's `cleanup_partial/1`
  cannot terminate it (it never learns the URI). The orphan then blocks
  future retries via the candidate-URI preflight.

  Round 10 makes the spawner own its own partial-spawn teardown: when
  this call FRESHLY started the Agent Kind and a LATER step
  (`ensure_pty_server/3`) fails, `spawn_for_local_pty/2` terminates the
  Agent Kind it itself started (`Ezagent.Kind.terminate/1`) BEFORE
  returning the error. The function now either fully succeeds or leaves
  ZERO residue. An `:already_started` Kind is never terminated — this
  call did not create it. Only the Kind PROCESS is terminated; lineage
  and workspace binding are Ezagent-domain registries the plugin must not
  touch (3-tier) — and `spawn_from_template_content/4` had not recorded
  either (it gates them on a `fresh?: true` success this path never
  returns).

  ## Domain.Pty PR-A (2026-05-21 SPEC v1)

  The cc-specific claude invocation (mcp.json generation, settings
  override path, `--dangerously-load-development-channels`,
  `--permission-mode bypassPermissions`) used to live inside
  `Ezagent.PluginCc.PtyServer.spawn_claude_directly/1` (historical).
  It now lives here (`build_claude_cmd/3`) because Domain.Pty.Server
  is Tier-2 and cannot reference cc-plugin modules like
  `EzagentPluginCc.McpConfigWriter`.
  The invocation is supplied as `cmd_override` on the Server init args
  — an argv LIST (codex HIGH-2), which Server runs under erlexec's PTY
  via `execve` with no shell.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "cc.agent"

  # PR-3 (domain.agent D2) — the config_dir path namespace. Declared explicitly
  # so `Ezagent.Sandbox.ConfigDir` builds `<Home>/cc-agents/<ws>/<name>` —
  # byte-identical to the pre-PR-3 cc layout (no migration).
  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: "cc"

  # #17 PR-A — the cc credential adapter (flavor-generic credential contract).
  @behaviour Ezagent.Agent.CredentialAdapter

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: "CLAUDE_CONFIG_DIR"

  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: [".credentials.json"]

  # #17 cascade PR-0 (§D6, codex H4) — the SECRET subset, disjoint from config.
  # For cc the credential home holds only the single token file, so the secret set
  # equals credential_relpaths/0; codex differs (config.toml is config, not secret).
  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: [".credentials.json"]

  # claude prints these when the OAuth access token is expired/missing (~daily). Pure
  # data — the PR-C PTY observer consumes them to notify the owner to re-`/login`.
  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals,
    do: [~r/Please run \/login/, "API Error: 403", ~r/API Error: 401/, ~r/Invalid API key/]

  # #1201 A② — the node's HOST claude login home (`$CLAUDE_CONFIG_DIR` else
  # `~/.claude`, claude's own resolution order). Consumed only through
  # `CredentialAdapter.host_login_source_dir/1`, which additionally requires a
  # present secret before the dir is usable as a source.
  @impl Ezagent.Agent.CredentialAdapter
  def host_login_dir,
    do: Ezagent.Credential.HomeRuntime.host_login_dir("CLAUDE_CONFIG_DIR", ".claude")

  # #17 PR-E — test/E2E credential provisioning (refresh-if-expired + copy). Delegates to
  # EzagentPluginCc.CredentialRefresh. Production users log in interactively, so this is
  # only invoked by the test/E2E harness.
  @impl Ezagent.Agent.CredentialAdapter
  def refresh_test_credentials(source, home, opts \\ []) do
    EzagentPluginCc.CredentialRefresh.provision(source, home, opts)
  end

  # #160 — credential-status view. Maps the cc-native freshness classification
  # (`EzagentPluginCc.CredentialFreshness.status/2`, which carries the distinct
  # `:missing`) onto the flavor-agnostic normalized enum. Read-only, no network,
  # no activation. `expires_at` is the OAuth token's epoch-ms `expiresAt` when
  # readable (cc is the one flavor with a real expiry).
  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(home, opts \\ []) do
    {status, detail} =
      case EzagentPluginCc.CredentialFreshness.status(home, opts) do
        :fresh ->
          {:authenticated, nil}

        {:stale, :expiring_soon} ->
          {:expiring, "OAuth token expiring soon — re-`claude /login`"}

        {:stale, :expired} ->
          {:expired, "OAuth token expired — run `claude /login` in the agent's config dir"}

        :missing ->
          {:missing, "No `.credentials.json` — the agent has never logged in (`claude /login`)"}

        :unknown ->
          {:unknown, nil}
      end

    %{
      status: status,
      detail: detail,
      expires_at: EzagentPluginCc.CredentialFreshness.expires_at(home)
    }
  end

  # SPEC 2026-06-01-flavor-generic-template-data (approach B): the
  # cc-specific template_data fields formerly hardcoded in
  # `AgentTemplate.to_template_data/2`. Reads atom-or-string content keys;
  # returns string keys; nil values are dropped by the caller. Output is
  # byte-for-byte the pre-fix cc set, so orchestrators + existing cc agents
  # are unaffected.
  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    # config_dir promotion (Allen 2026-06-03): `config_dir` is now a
    # UNIVERSAL AgentTemplate field — `AgentTemplate.to_template_data/2`
    # emits it in the universal base under the flavor-neutral `"config_dir"`
    # data key. cc does NOT re-emit it here; cc's consume path
    # (`build_claude_config_env/2` / `create_agent_config_dir/2`) READS the
    # neutral `"config_dir"` key and applies claude semantics
    # (`CLAUDE_CONFIG_DIR`, the per-agent copy, the claude file format).
    %{
      "operator_settings_path" => Ezagent.Kind.Template.content_field(content, :settings_path),
      "operator_mcp_config_path" =>
        Ezagent.Kind.Template.content_field(content, :mcp_config_path),
      "api_key_helper" => Ezagent.Kind.Template.content_field(content, :api_key_helper),
      "role" => Ezagent.Kind.Template.content_field(content, :role),
      "model" => Ezagent.Kind.Template.content_field(content, :model),
      "effort" => Ezagent.Kind.Template.content_field(content, :effort),
      "permission_mode" => Ezagent.Kind.Template.content_field(content, :permission_mode),
      "tools" => Ezagent.Kind.Template.content_field(content, :tools),
      # §5.B follow-up (c) — the TEST/E2E source-credential path. The
      # refresh-if-expired provisioner (`refresh_test_credentials/3`) needs a
      # SOURCE `.credentials.json` to refresh FROM on the source agent's OWN
      # respawn (the respawn path deliberately doesn't re-materialize the
      # config_dir, so a token that expired between create and respawn would
      # otherwise stay expired). Persisting this content field into the
      # Template-Class data carries it into the sandbox `respawn_template_data`
      # (it is NOT a `cascade`/reserved key, so `sanitize_respawn_template_data`
      # preserves it), which is exactly what
      # `Spawn.maybe_reprovision_source_from_respawn_data/2` reads. Production
      # interactive-login agents never set it (nil → dropped by the caller), so
      # the production respawn path stays a no-op.
      "credential_source" => Ezagent.Kind.Template.content_field(content, :credential_source)
    }
  end

  def template_data_extra(_), do: %{}

  @impl Ezagent.Kind.Template
  defdelegate config_schema, to: Ezagent.PluginCc.Template.CcAgent.ConfigSchema, as: :fields

  @impl Ezagent.Kind.Template
  def compile(resolved, params),
    do: Ezagent.Kind.Template.compile_cc_agent_data(resolved, params, &template_data_extra/1)

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_no_stale_config_dir_key(tmpl),
         :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_sandbox_keys(tmpl),
         :ok <- Ezagent.PluginCc.Template.CcAgent.ConfigSchema.validate_values(tmpl),
         :ok <- check_role(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  # config_dir promotion (Allen 2026-06-03) — FAIL LOUD on a stale
  # `"claude_config_dir"` data key (codex P2 closure). The per-agent
  # config-home is now the universal, flavor-neutral `"config_dir"` key;
  # `"claude_config_dir"` is NO LONGER part of the contract. A persisted /
  # hand-written template still carrying it would otherwise pass validate
  # (unknown keys are ignored) and then SILENTLY spawn without its isolated
  # config dir / `CLAUDE_CONFIG_DIR` (the consume path reads only
  # `"config_dir"`). Per `feedback_let_it_crash_no_workarounds` (no
  # back-compat shim — DB is wiped + rebuilt), we reject it structurally so
  # the misconfiguration is visible, NOT translated.
  defp check_no_stale_config_dir_key(tmpl) do
    if Map.has_key?(tmpl, "claude_config_dir") do
      {:error,
       {:stale_config_dir_key, "claude_config_dir",
        "config_dir is now the universal, flavor-neutral data key (Allen " <>
          "2026-06-03); rename `claude_config_dir` → `config_dir`. No back-compat " <>
          "shim — see feedback_let_it_crash_no_workarounds."}}
    else
      :ok
    end
  end

  # Phase 7 completion PR-1 (SPEC §1.5 (c)) — the four sandbox keys are
  # OPTIONAL. Absent ⇒ legacy behavior (the 3-key form still validates).
  # When present, each must be a non-empty string.
  # config_dir promotion (Allen 2026-06-03): the per-agent config-home key
  # is the universal, flavor-neutral `"config_dir"` (NOT `"claude_config_dir"`).
  @optional_sandbox_keys ~w(operator_settings_path operator_mcp_config_path
                            config_dir api_key_helper)

  defp check_optional_sandbox_keys(tmpl) do
    Enum.reduce_while(@optional_sandbox_keys, :ok, fn key, :ok ->
      case Map.fetch(tmpl, key) do
        :error -> {:cont, :ok}
        {:ok, v} when is_binary(v) and v != "" -> {:cont, :ok}
        {:ok, bad} -> {:halt, {:error, {:invalid_sandbox_key, key, bad}}}
      end
    end)
  end

  # `role` is optional (absent ⇒ default/legacy cc agent). Accept BOTH string and
  # atom ingress (JSON round-trips don't preserve atoms; on-disk form is a string).
  # Phase 3 ③ T4 (2026-06-28) — GENERALIZED beyond the hardcoded
  # `default`/`orchestrator` allowlist: any OTHER name is accepted IFF it is a
  # REGISTERED role (`RecipeRegistry.lookup/1`), else fail-loud `{:invalid_role,_}`.
  # Opens the gate to `pm-coordinator`/… so a non-orchestrator cc role reaches the
  # T2-generalized `OrchestratorBootstrap` skill-install — a GENERIC gate over any
  # role, NOT a per-role branch (机制 ≠ 业务). `default` (no-role) + `orchestrator`
  # (built-in) stay a PURE fast-path: behavior byte-identical to pre-T4 AND
  # `validate/1` stays DB-free for them (it IS run in pure `ExUnit.Case` with
  # `role: "orchestrator"` via `to_template_data/2`); only the new path hits the DB.
  defp check_role(tmpl) do
    case Map.fetch(tmpl, "role") do
      :error ->
        :ok

      {:ok, r} when r in ["default", "orchestrator", :default, :orchestrator] ->
        :ok

      {:ok, r} when is_binary(r) or is_atom(r) ->
        name = if is_atom(r), do: Atom.to_string(r), else: r

        case Ezagent.Agent.RecipeRegistry.lookup(name) do
          {:ok, _role} -> :ok
          :error -> {:error, {:invalid_role, r}}
        end

      {:ok, bad} ->
        {:error, {:invalid_role, bad}}
    end
  end

  defp check_class(%{"class" => "cc.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # Cleanup-2: shared entity-agent-URI validator lives in core
  # (Ezagent.Kind.Template) — byte-identical across every flavor.
  defp check_agent_uri(tmpl), do: Ezagent.Kind.Template.check_agent_uri(tmpl)

  defp check_cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "", do: :ok
  defp check_cwd(_), do: {:error, :missing_cwd}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    agent_uri = Ezagent.URI.new!(uri_str)

    with :ok <- Ezagent.AgentFlavorAttributes.put_from_template_class(agent_uri, __MODULE__) do
      # PR-D2 idempotency short-circuit: if BOTH the Agent Kind and the
      # PtyServer are already alive we have nothing to do. Each plugin
      # re-running Workspace.Loader.load_all/0 hits this on subsequent
      # passes; the first pass spawns, the rest no-op.
      #
      # codex round-6 HIGH-1 — the 3-element `{:ok, uris, %{fresh?: _}}`
      # return carries whether THIS call STARTED the Agent Kind worker.
      # The short-circuit means the worker pre-existed → `fresh?: false`.
      cond do
        agent_kind_alive?(agent_uri) and pty_server_alive?(agent_uri) ->
          {:ok, [agent_uri], %{fresh?: false}}

        true ->
          Ezagent.PluginCc.Template.CcAgent.Spawn.spawn_for_local_pty(
            agent_uri,
            tmpl,
            workspace_uri
          )
      end
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # PR-3T (#25 burn-down) — the spawn / PTY / grant-cascade machinery was
  # extracted VERBATIM into `Ezagent.PluginCc.Template.CcAgent.Spawn`
  # (`spawn_for_local_pty/3` + `create_agent_config_dir_with_grant/2` +
  # `revalidate_grant_before_launch/1` + `ensure_agent_kind/1` +
  # `ensure_pty_server/3` + `owns_this_agent?/2` +
  # `ensure_subprocess_alive_best_effort/2` + `config_home_opts/0` + the
  # orchestrator boot-readiness gate). The `@impl instantiate/3` and
  # `@impl ensure_subprocess_alive/2` callbacks STAY here and delegate the
  # orchestration steps into that module. `handle_spawn_failure/2`,
  # `create_agent_config_dir/2`, `try_role_bootstrap/3`,
  # `orchestrator_recipe?/1` and `reject_stale_config_dir_data_key!/1` stay
  # here (CredentialAdapter `__MODULE__` identity / shared-helper dedup /
  # external callers) and `Spawn` calls back into them.
  # ────────────────────────────────────────────────────────────────────────
  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B —
  # orchestrator-role bootstrap (skill copy + CLAUDE.md hint).
  # ────────────────────────────────────────────────────────────────────────
  #
  # When the cc template carries `"role" => "orchestrator"`, this helper:
  #
  #   1. Copies the `ezagent-session-orchestrator` skill tree from the
  #      umbrella root into `<config_dir>/skills/ezagent-session-orchestrator/`
  #      via `File.cp_r/2`. Skipped when the destination already exists
  #      (idempotent re-instantiate).
  #   2. Appends `## Use the ezagent-session-orchestrator skill for all
  #      session coordination work.` to `<config_dir>/CLAUDE.md`,
  #      creating the file if missing. Gated on grep-for-marker so a
  #      re-instantiate does NOT duplicate the line.
  #
  # `EZAGENT_AGENT_ROLE=orchestrator` is added to `cmd_env` separately
  # by `build_claude_config_env/2` (so it lands on the claude process
  # even on demand-restart paths that bypass this helper).
  #
  # Failure modes (codex PR #408 review HIGH-3 — degraded-mode return,
  # not teardown — see `spawn_for_local_pty/2` for the post-fix handler):
  #
  #   * Skill source missing (override) — `{:error, {:skill_source_missing, _}}`.
  #   * Skill source missing (auto-walk) — `{:error, {:skill_source_not_found,
  #     attempted_paths}}`.
  #   * `File.cp_r/2` failure — `{:error, {:skill_copy_failed, _}}`.
  #   * CLAUDE.md write failure — `{:error, {:claude_md_hint_failed, _}}`.
  #
  # Skipped when role is `:default` / `"default"` / absent — no-op.
  # Skipped when `config_dir` is `nil` (template has no
  # `config_dir` reference; nowhere to copy the skill).
  @doc false
  @spec apply_orchestrator_recipe_bootstrap(map(), String.t() | nil) ::
          :ok | {:error, term()}
  def apply_orchestrator_recipe_bootstrap(tmpl, config_dir) do
    Ezagent.PluginCc.Template.OrchestratorBootstrap.bootstrap(tmpl, config_dir)
  end

  @doc false
  @spec attach_role_sandbox_content(map()) :: {:ok, map()} | {:error, term()}
  def attach_role_sandbox_content(tmpl) when is_map(tmpl) do
    Ezagent.PluginCc.Template.OrchestratorBootstrap.attach_role_sandbox_content(tmpl)
  end

  # codex PR #408 review HIGH-3 — wrap `apply_orchestrator_recipe_bootstrap/2`
  # so a role-bootstrap failure DOES NOT tear down the agent. The agent
  # is allowed to spawn as a plain cc agent (the SKILL is UX, not
  # load-bearing for claude itself).
  #
  # Returns `{:ok, meta}` always when role is non-orchestrator (empty
  # meta) OR role is orchestrator and bootstrap succeeded (empty meta).
  # On bootstrap failure returns `{:ok, %{role_degraded: %{...}}}` — the
  # `:ok` lets the `with` chain in `spawn_for_local_pty/2` continue to
  # `ensure_pty_server/3`. The degraded info propagates up so the caller
  # can notify the session owner (Invariant #9).
  #
  # Emits a `[:ezagent, :cc, :role_bootstrap, :failed]` telemetry event
  # so monitoring observes the failure independent of caller wiring.
  @doc false
  @spec try_role_bootstrap(map(), String.t() | nil, URI.t()) :: {:ok, map()}
  def try_role_bootstrap(tmpl, config_dir, %URI{} = agent_uri) do
    Ezagent.PluginCc.Template.OrchestratorBootstrap.try_apply(tmpl, config_dir, agent_uri)
  end

  @doc false
  @spec orchestrator_recipe?(map()) :: boolean()
  def orchestrator_recipe?(tmpl),
    do: Ezagent.PluginCc.Template.OrchestratorBootstrap.orchestrator_recipe?(tmpl)

  @doc """
  The CLAUDE.md hint line appended for orchestrator-role cc agents.
  Public so tests can assert exact content (SPEC Gap B B2 / B4).
  """
  @spec orchestrator_hint_line() :: String.t()
  def orchestrator_hint_line, do: Ezagent.PluginCc.Template.OrchestratorBootstrap.hint_line()

  # PR-3T — body extracted VERBATIM to `CcAgent.Spawn.handle_spawn_failure/2`
  # (spawn-failure machinery). Kept here as a thin wrapper because external
  # callers (cc + codex grant/cascade tests) reference `CcAgent.handle_spawn_failure/2`.
  @doc false
  @spec handle_spawn_failure(URI.t(), term()) :: {:error, term()}
  def handle_spawn_failure(agent_uri, reason),
    do: Ezagent.PluginCc.Template.CcAgent.Spawn.handle_spawn_failure(agent_uri, reason)

  # PR-3T — the spawn-build delegates (`build_pty_params/3`,
  # `build_pty_params_for_env/4`, `build_claude_cmd/3`,
  # `resolve_claude_executable/1`, `resolve_config_home/2`,
  # `assemble_settings_mcp_args/3`) were relocated VERBATIM to
  # `CcAgent.Spawn` (spawn / PTY / config-build machinery). Kept here as
  # thin delegates because external callers (cc + codex tests, SpawnPlan)
  # reference them as `CcAgent.<fn>`.
  @doc false
  defdelegate build_pty_params(agent_uri, cwd, tmpl), to: Ezagent.PluginCc.Template.CcAgent.Spawn

  @doc false
  defdelegate build_pty_params_for_env(agent_uri, cwd, tmpl, env),
    to: Ezagent.PluginCc.Template.CcAgent.Spawn

  @doc false
  defdelegate build_claude_cmd(agent_uri, agent_cwd, tmpl),
    to: Ezagent.PluginCc.Template.CcAgent.Spawn

  @doc false
  @spec resolve_claude_executable(URI.t()) :: {:ok, String.t()} | {:error, :claude_not_found}
  defdelegate resolve_claude_executable(agent_uri), to: Ezagent.PluginCc.Template.CcAgent.Spawn

  @doc false
  defdelegate resolve_config_home(agent_uri, tmpl), to: Ezagent.PluginCc.Template.CcAgent.Spawn

  # config_dir promotion (Allen 2026-06-03) — FAIL LOUD on a stale
  # `"claude_config_dir"` data key (codex P2 closure). Used by the cc consume
  # path (`create_agent_config_dir/2`, `build_claude_config_env/2`), which is
  # reached on the loader/boot path that bypasses `validate/1`. The per-agent
  # config-home is the universal, flavor-neutral `"config_dir"` key; the
  # cc-named key is NO LONGER part of the contract. A template still carrying
  # it would otherwise be silently dropped → the agent spawns without its
  # isolated config dir / `CLAUDE_CONFIG_DIR`. No back-compat shim
  # (`feedback_let_it_crash_no_workarounds`) — raise so the misconfiguration
  # is visible.
  # Cleanup-2: single cc-plugin-internal definition; `SpawnPlan` delegates here
  # (was a byte-identical fork). Public so the sibling SpawnPlan can reuse it.
  @doc false
  @spec reject_stale_config_dir_data_key!(map()) :: :ok
  def reject_stale_config_dir_data_key!(tmpl) when is_map(tmpl) do
    if Map.has_key?(tmpl, "claude_config_dir") do
      raise ArgumentError,
            "cc.agent: stale `claude_config_dir` data key — config_dir is now the " <>
              "universal, flavor-neutral `config_dir` key (Allen 2026-06-03). Rename " <>
              "`claude_config_dir` → `config_dir`. No back-compat shim " <>
              "(feedback_let_it_crash_no_workarounds)."
    else
      :ok
    end
  end

  def reject_stale_config_dir_data_key!(_), do: :ok

  # config_dir promotion (Allen 2026-06-03) — PR-F lazy FORWARD migration.
  # `reject_stale_config_dir_data_key!/1` correctly fail-louds on a stale
  # `"claude_config_dir"` arriving on the FRESH create/validate path (a code-level
  # misconfiguration). But agents SEEDED before the rename persisted their
  # `respawn_template_data` with the old key; on a cold restart that persisted data
  # is replayed verbatim through the same build path, so the fail-loud would crash-
  # loop a legitimate pre-rename agent forever (the 传话游戏 relay "no reply" bug,
  # 2026-06-04). This migrates the legacy key forward — applied ONLY at the
  # rehydration boundary (`ensure_subprocess_alive/2`), NOT on the fresh path — so
  # persisted agents boot while a genuinely misconfigured fresh template still
  # fails loud. Schema-evolution of persisted data, not a back-compat shim
  # (cf. PR-4 cold-restart state normalization).
  #
  # The current contract key wins: if BOTH keys are present the new `"config_dir"`
  # is kept and the legacy duplicate is dropped.
  @doc false
  @spec migrate_legacy_config_dir_key(map()) :: map()
  def migrate_legacy_config_dir_key(tmpl) when is_map(tmpl) do
    if Map.has_key?(tmpl, "claude_config_dir") do
      {legacy, rest} = Map.pop(tmpl, "claude_config_dir")
      Map.put_new(rest, "config_dir", legacy)
    else
      tmpl
    end
  end

  @doc false
  @spec assemble_settings_mcp_args(String.t(), String.t(), map()) :: [String.t()]
  defdelegate assemble_settings_mcp_args(mandatory_settings_path, bridge_mcp_path, tmpl),
    to: Ezagent.PluginCc.Template.CcAgent.Spawn

  defp agent_kind_alive?(agent_uri) do
    Ezagent.LocalRuntime.kind_alive?(agent_uri)
  end

  defp pty_server_alive?(agent_uri), do: Ezagent.Domain.Pty.alive?(agent_uri)

  # --- Per-agent config_dir + extension management (PR3 2026-05-24) -----------
  #
  # Allen 2026-05-24 architectural decision (PR2 + PR3): every spawned cc
  # agent gets its OWN config dir (copied from the template`s reference
  # universal `config_dir` at spawn). The dir is the per-agent CLAUDE_CONFIG_DIR
  # — claude reads `.credentials.json` etc. from it — and houses an
  # installable extensions tree at `<dir>/.claude/plugins/<ext_id>/`
  # (Anthropic Claude Code "plugin" bundles, per the marketplace cache
  # convention at `~/.claude/plugins/cache/<marketplace>/<plugin>/<ver>/`).
  #
  # cc Template Class implements ALL THREE extension callbacks together
  # (the all-or-nothing invariant in
  # `apps/ezagent_core/test/invariants/template_class_extension_contract_test.exs`
  # enforces this).

  # PR3 layout — what `agent_config_dir/1` looks like on disk:
  #
  #   <Ezagent.Home.path("cc-agents")>/<workspace>/<flavor>_<name>/   (chmod 700)  # arch-allow: doc comment, not a call
  #   ├── .credentials.json                        (chmod 600 — copied from template)
  #   └── .claude/
  #       └── plugins/
  #           ├── <ext_id_1>/.claude-plugin/plugin.json
  #           └── <ext_id_2>/...
  #
  # `agent_config_dir/1` is the canonical path builder; the cleanup
  # callback (`destroy_config_dir/2`) verifies the path it removes
  # equals this — defense-in-depth against being handed a bogus path.

  # PR-3 (domain.agent D2) — the per-agent config_dir TARGET path authority moved
  # to `Ezagent.Sandbox.ConfigDir` (core, the sandbox concept owns the location).
  # This thin delegate keeps cc's internal callers (rollback) + the canonical-path
  # contract working; the scheme itself no longer lives in the plugin.
  @doc false
  def agent_config_dir(%URI{} = agent_uri) do
    Ezagent.Credential.HomeRuntime.agent_config_dir(agent_uri, __MODULE__)
  end

  # `list_extensions/1` — scan `<config_dir>/.claude/plugins/*` for
  # installed Claude Code plugin bundles. A bundle is recognized by
  # `<dir>/.claude-plugin/plugin.json` (the manifest the
  # Anthropic CC marketplace stores). The manifest's `name` / `description`
  # surface in the LV; the directory NAME is the `id` (operators can
  # rename bundles by dir-rename, but the LV uses dir-name as the
  # stable handle).
  @impl Ezagent.Kind.Template
  def list_extensions(config_dir) when is_binary(config_dir) do
    plugins_dir = Path.join([config_dir, ".claude", "plugins"])

    case File.ls(plugins_dir) do
      {:ok, entries} ->
        extensions =
          entries
          |> Enum.filter(fn name -> File.dir?(Path.join(plugins_dir, name)) end)
          |> Enum.map(fn dir_name -> read_extension_manifest(plugins_dir, dir_name) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.name)

        {:ok, extensions}

      {:error, :enoent} ->
        # No plugins dir yet (agent has none installed). Not an error.
        {:ok, []}

      {:error, reason} ->
        {:error, {:list_plugins_failed, reason}}
    end
  end

  def list_extensions(_), do: {:error, :invalid_config_dir}

  # Read `<plugins_dir>/<dir_name>/.claude-plugin/plugin.json` and turn
  # it into the standard extension descriptor. Returns `nil` if the dir
  # is NOT a plugin bundle (no manifest) — those are silently filtered
  # out (operator dropped some unrelated file in plugins/).
  defp read_extension_manifest(plugins_dir, dir_name) do
    manifest_path = Path.join([plugins_dir, dir_name, ".claude-plugin", "plugin.json"])

    with {:ok, body} <- File.read(manifest_path),
         {:ok, json} <- Jason.decode(body) do
      %{
        id: dir_name,
        name: Map.get(json, "name", dir_name),
        description: Map.get(json, "description", ""),
        # presence-in-dir == enabled (uninstalling = toggle off = rmdir)
        enabled?: true
      }
    else
      _ -> nil
    end
  end

  # `toggle_extension/3` — install or uninstall an extension bundle in
  # the per-agent config dir.
  #
  # PR3 V1 scope: TOGGLE-OFF only is fully implemented (= `rm -rf`
  # `<config_dir>/.claude/plugins/<ext_id>/`). TOGGLE-ON is NOT
  # implemented yet — needs a SOURCE (a marketplace registry / a
  # known plugin cache to copy FROM); the LV will surface a
  # "Unsupported: install from marketplace" message until that
  # source is wired (separate PR — likely once marketplace integration
  # lands). For now `toggle_extension(_, _, true)` returns
  # `{:error, :install_from_source_not_implemented}` so the LV can
  # render a clear "not yet available" hint.
  @impl Ezagent.Kind.Template
  def toggle_extension(config_dir, extension_id, enabled?)
      when is_binary(config_dir) and is_binary(extension_id) and is_boolean(enabled?) do
    target = Path.join([config_dir, ".claude", "plugins", extension_id])

    cond do
      # Pre-validate extension_id BEFORE Path.join can do anything
      # dangerous (an absolute path or `/` segment would otherwise
      # let toggle escape the plugins dir).
      not valid_extension_id?(extension_id) ->
        {:error, :unsafe_extension_path}

      # Belt-and-braces post-join check.
      not safe_extension_path?(config_dir, target) ->
        {:error, :unsafe_extension_path}

      enabled? == false ->
        case File.rm_rf(target) do
          {:ok, _removed} -> :ok
          {:error, reason, _path} -> {:error, {:rm_failed, reason}}
        end

      enabled? == true ->
        # PR3 V1: install-from-source is deferred to the marketplace
        # PR. An operator can still install manually (`cp -r` a bundle
        # under `<config_dir>/.claude/plugins/`); the LV reflects the
        # new state on next refresh.
        {:error, :install_from_source_not_implemented}
    end
  end

  def toggle_extension(_, _, _), do: {:error, :invalid_args}

  # Defense-in-depth: the target plugin path MUST be under the agent's
  # `<config_dir>/.claude/plugins/` subtree. A maliciously-crafted
  # `extension_id` like `"../../etc"` or `"/etc/passwd"` would
  # otherwise let toggle-off delete arbitrary paths.
  #
  # Three checks (any failure → unsafe):
  #   1. ext_id contains no `/` (would let Path.join concatenate
  #      additional path segments)
  #   2. ext_id is not absolute (would let Path.join replace prefix —
  #      e.g. `Path.join(["/a/b", "/c"])` discards `/a/b`)
  #   3. Path.expand(target) is under Path.expand(plugins_dir) — the
  #      belt + braces final check (catches any tricks the first two
  #      missed)
  defp safe_extension_path?(config_dir, target) do
    plugins_dir = Path.expand(Path.join([config_dir, ".claude", "plugins"]))
    actual = Path.expand(target)
    String.starts_with?(actual, plugins_dir <> "/")
  end

  # Pre-validate the extension_id BEFORE it gets near Path.join.
  defp valid_extension_id?(ext_id) when is_binary(ext_id) and ext_id != "" do
    not String.contains?(ext_id, "/") and
      not String.contains?(ext_id, "\\") and
      ext_id != "." and
      ext_id != ".."
  end

  defp valid_extension_id?(_), do: false

  # `destroy_config_dir/2` — `rm -rf <config_dir>`. Called at agent
  # teardown by `Ezagent.ActionSet.Sandbox.invoke(:destroy, ...)`.
  #
  # Defense-in-depth (PR-3 DD-5): the path MUST equal the canonical TARGET for
  # this agent_uri — checked by the core authority `Ezagent.Sandbox.ConfigDir`
  # (the path scheme lives there now, not in the plugin). A buggy caller passing
  # an arbitrary path (e.g. `/`) is rejected.
  @impl Ezagent.Kind.Template
  def destroy_config_dir(%URI{} = agent_uri, config_dir) when is_binary(config_dir) do
    namespace = Ezagent.Kind.Template.namespace_of(__MODULE__)

    if Ezagent.Sandbox.ConfigDir.safe_to_destroy?(config_dir, agent_uri, namespace) do
      case File.rm_rf(config_dir) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, {:rm_rf_failed, reason}}
      end
    else
      {:error,
       {:path_mismatch,
        expected: Ezagent.Sandbox.ConfigDir.path(agent_uri, namespace), got: config_dir}}
    end
  end

  def destroy_config_dir(_, _), do: {:error, :invalid_args}

  # --- PTY-orphan-restart 2026-05-26 — re-spawn the claude PTY on boot ------
  #
  # Invoked by `Ezagent.ActionSet.Sandbox`'s post_init/2 continuation
  # after the Agent Kind has been rehydrated from snapshot on a phx
  # restart. We check whether the PtyServer (which OWNS the claude TUI
  # subprocess) is alive for this agent_uri; if absent, we re-run the
  # same `ensure_pty_server/3` path `instantiate/3` uses for fresh
  # spawns.
  #
  # ## Why this is needed
  #
  # The two-layer process model:
  #   1. Agent Kind (Elixir GenServer) — OTP-supervised, recovers from
  #      snapshot.
  #   2. PtyServer + claude TUI subprocess — NOT OTP-supervised across
  #      BEAM restarts. Dies with the BEAM (or worse, survives as an
  #      OS orphan on brutal kill).
  #
  # On a normal `instantiate/3` boot path the codex round-8 fix
  # IMMEDIATELY returns when the Agent Kind is `:already_started` —
  # without starting the PTY. That's correct for the "foreign Kind
  # adoption" case but it CAN'T be the boot-restore path. The
  # boot-restore path goes through this callback instead, which knows
  # the agent is OURS (it was OURS at original-spawn time; the
  # respawn_template_data was persisted into our sandbox slice then).
  #
  # ## Idempotency
  #
  # `Ezagent.Domain.Pty.alive?/1` is the single source of truth. If
  # YES, return :ok (subprocess survived the restart somehow — would
  # only happen in a hot-code-update scenario; under normal
  # SIGTERM/SIGKILL → BEAM restart, the PtyServer dies + the OS
  # claude is reaped by erlexec OR by our OrphanReaper).
  #
  # On failure we return `{:error, reason}` — Sandbox.post_init/2
  # re-raises and the Kind.Server supervisor restarts with backoff
  # (`feedback_let_it_crash_no_workarounds`).
  @impl Ezagent.Kind.Template
  def ensure_subprocess_alive(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    # PR-F — forward-migrate persisted respawn data from agents seeded BEFORE the
    # `claude_config_dir` → `config_dir` rename, so the downstream build path's
    # fail-loud stale-key reject doesn't crash-loop a legitimate pre-rename agent
    # on cold restart. The fresh create/validate paths keep the fail-loud.
    respawn_data = migrate_legacy_config_dir_key(respawn_data)

    cond do
      pty_server_alive?(agent_uri) ->
        :ok

      true ->
        with {:ok, respawn_data} <-
               Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data(agent_uri, respawn_data) do
          # PtyServer absent — rebuild via the grant-guarded respawn entrypoint.
          # `Spawn.respawn_subprocess/2` enforces the #17 cascade §5.1 grant
          # revocation boundary BEFORE launch, then drives the (private) PTY
          # launcher + orchestrator boot-readiness gate. The raw launcher is no
          # longer reachable without that gate (codex PR-3T HIGH — chokepoint).
          Ezagent.PluginCc.Template.CcAgent.Spawn.respawn_subprocess(agent_uri, respawn_data)
        end
    end
  end

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  # Create a fresh per-agent config dir by copying the template's
  # reference dir into the agent-private location.
  #
  # Called from `spawn_for_local_pty/2` BEFORE PTY launch so the
  # cc process gets `CLAUDE_CONFIG_DIR=<per-agent-dir>` and reads its
  # own private credentials/settings. The reference dir is the
  # template's universal `config_dir` field (now interpreted as
  # "reference" — not the dir the process actually uses).
  #
  # config_dir promotion (Allen 2026-06-03): the reference config-home
  # arrives under the UNIVERSAL, flavor-neutral `"config_dir"` data key
  # (was `"claude_config_dir"`); cc reads it here as its claude reference
  # dir to copy per-agent.
  #
  # Returns `{:ok, path}` where path is the absolute per-agent dir.
  # If no reference dir is configured on the template, returns
  # `{:ok, nil}` — agent runs without `CLAUDE_CONFIG_DIR` (legacy
  # behavior, valid for agents that need no sandbox).
  # PR-3 (domain.agent D2) — MATERIALIZE the flavor reference into the per-agent
  # config_dir TARGET the DOMAIN allocated (`"allocated_config_dir"`, injected by
  # `Ezagent.Kind.Template.provision_and_instantiate/4`). The plugin no longer
  # computes the path; `agent_uri` is retained only for the legacy signature.
  # Return: `{:ok, dir}` / `{:ok, nil}` on the non-cascade path (backward-compatible), OR
  # `{:ok, dir, {:grant, agent_uri_str, version}}` on the cascade path — the third element
  # carries the grant version validated at materialize so `spawn_for_local_pty/3` can
  # re-validate the grant IMMEDIATELY before the PTY launch (codex CRITICAL §5.1).
  @doc false
  @spec create_agent_config_dir(URI.t(), map()) ::
          {:ok, String.t() | nil}
          | {:ok, String.t(), {:grant, String.t(), non_neg_integer()}}
          | {:error, term()}
  def create_agent_config_dir(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    reject_stale_config_dir_data_key!(tmpl)

    with {:ok, tmpl} <- attach_role_sandbox_content(tmpl) do
      Ezagent.Credential.HomeRuntime.create_agent_config_dir(
        agent_uri,
        tmpl,
        __MODULE__,
        Ezagent.PluginCc.Template.CcAgent.Spawn.config_home_opts()
      )
    end
  end

  # --- Ezagent.UI.Form ---------------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI",
        required: true,
        placeholder: "cc_architect"
      },
      %{
        name: "cwd",
        type: :path,
        label: "Working directory",
        required: true,
        placeholder: "/Users/me/Workspace/proj"
      }
    ]
  end
end

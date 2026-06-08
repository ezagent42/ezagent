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
  ESR domain layer. But the Template Class itself was still not
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
  and workspace binding are ESR-domain registries the plugin must not
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

  # Compile-time env capture. `Mix.env()` is NOT available in a compiled
  # release (Mix is not loaded — see migration_gate.ex), so calling it at
  # runtime would crash the orchestrator PTY spawn path. The deployment env
  # is fixed at compile time, so a module attribute is both release-safe and
  # correct. (codex final-review Q1.)
  @compile_env Mix.env()

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

  # #17 PR-E — test/E2E credential provisioning (refresh-if-expired + copy). Delegates to
  # EzagentPluginCc.CredentialRefresh. Production users log in interactively, so this is
  # only invoked by the test/E2E harness.
  @impl Ezagent.Agent.CredentialAdapter
  def refresh_test_credentials(source, home, opts \\ []) do
    EzagentPluginCc.CredentialRefresh.provision(source, home, opts)
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
    # Only the cc-specific extras remain owned here.
    %{
      "operator_settings_path" => content_field(content, :settings_path),
      "operator_mcp_config_path" => content_field(content, :mcp_config_path),
      "api_key_helper" => content_field(content, :api_key_helper),
      "role" => content_field(content, :role)
    }
  end

  def template_data_extra(_), do: %{}

  # AgentTemplate `content` may carry atom (fresh) or string (post-JSON)
  # keys — read tolerantly. Cleanup-2: shared tolerant reader lives in core.
  defp content_field(content, key), do: Ezagent.Kind.Template.content_field(content, key)

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_no_stale_config_dir_key(tmpl),
         :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_sandbox_keys(tmpl),
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

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B — `role`
  # is optional. Absent ⇒ default role (legacy cc agents). When
  # orchestrator, `instantiate/3` additionally copies the
  # `ezagent-session-orchestrator` skill into the per-agent config dir
  # and appends a CLAUDE.md hint pointing at it, plus sets
  # `EZAGENT_AGENT_ROLE=orchestrator` in `cmd_env`.
  #
  # codex PR #408 review LOW — accept BOTH string and atom forms on
  # ingress. The SPEC type reads `:default | :orchestrator` (atoms); the
  # implementer chose strings because JSON round-trips don't preserve
  # atoms (snapshot reload). We normalise on read here (validator) AND on
  # read in `orchestrator_role?/1` so callers can pass either form. The
  # CANONICAL on-disk form (seed + AgentTemplate slice) stays the string
  # `"orchestrator"` so snapshot round-trips don't generate atoms (no
  # atom-table-exhaustion exposure); the validator only accepts both
  # shapes so atom-literal call sites compile cleanly.
  defp check_role(tmpl) do
    case Map.fetch(tmpl, "role") do
      :error ->
        :ok

      {:ok, r} when r in ["default", "orchestrator", :default, :orchestrator] ->
        :ok

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
          spawn_for_local_pty(agent_uri, tmpl, workspace_uri)
      end
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # V1 fix Allen 2026-05-21: template instantiate PRODUCES the Kind.
  # Before this fix, instantiate started only PtyServer and assumed
  # someone else (AgentNewLive's direct SpawnRegistry.spawn call) had
  # already created the Agent Kind. The new flow:
  #
  # 1. Ensure the Agent Kind exists (via SpawnRegistry — routed by
  #    chat plugin's "entity" spawn fn to AgentSupervisor).
  # 2. Start the PtyServer for this agent_uri.
  #
  # Both steps are idempotent: SpawnRegistry returns
  # `{:error, {:already_started, _}}` for an existing Agent Kind, and
  # the PtyServer's :via Registry collapses concurrent starts.
  defp spawn_for_local_pty(agent_uri, tmpl, workspace_uri) do
    cwd = Map.fetch!(tmpl, "cwd")

    # codex round-6 HIGH-1 — `ensure_agent_kind/1` reports whether THIS
    # call STARTED the Agent Kind worker (`:started`) or adopted a
    # pre-existing one (`:already_started`). The worker IS the Agent
    # Kind; the PtyServer is a sidecar — so the worker's freshness is
    # the Agent Kind's freshness. Threaded out as `%{fresh?: _}`.
    #
    # codex round-8 HIGH-1 — the fresh-check gates the PTY sidecar.
    # When the Agent Kind was `:already_started` (a worker this call
    # did NOT create), return `fresh?: false` IMMEDIATELY without
    # calling `ensure_pty_server/3`. Starting a PTY / `claude` sidecar
    # for a pre-existing (possibly foreign or orphaned) worker would
    # make a rejected adoption non-zero-side-effect. The Template Class
    # only brings up a sidecar for a worker IT freshly started; whether
    # to adopt a pre-existing worker is the caller's decision.
    with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri) do
      case started_or_adopted do
        :already_started ->
          # Codex PR3 round-2 HIGH-2 — DO NOT call create_agent_config_dir
          # from the loser branch. A concurrent :started winner may be
          # mid-cp_r (marker not yet written); the loser would see
          # marker-absent and rm_rf the dir the winner is still copying.
          # The winner is responsible for dir creation; the loser just
          # adopts. The Agent slice was already populated by the
          # winner's record_sandbox_state when it spawned — slice still
          # carries the path.
          #
          # We also do NOT supply :config_dir_path in meta. The caller's
          # record_sandbox_state skips slice-dispatch when meta lacks
          # :config_dir_path (codex round-2 HIGH-1 fix in Agent module),
          # so the existing slice is preserved verbatim.
          #
          # PTY-orphan-restart 2026-05-26 round-2 (codex finding #1):
          # the :already_started branch USED to return immediately,
          # which leaves a Kind alive without a PtyServer in the
          # demand-spawn case (chat router spawned the Kind first;
          # then Workspace.Loader hits this branch and short-circuits).
          # Round-8's "refuse to adopt foreign Kind" stays correct AS
          # AN INVARIANT — we only bring up the PTY when we can prove
          # the agent belongs to THIS workspace by URI-segment match.
          # When the agent's workspace segment matches `workspace_uri`,
          # the operator's workspace template legitimately owns this
          # URI (this is the boot/demand-restore case Workspace.Loader
          # hits). When it does NOT match, this is a cross-workspace
          # adoption attempt (codex round-8's test case) — we MUST
          # refuse the PTY spawn.
          if owns_this_agent?(agent_uri, workspace_uri) do
            _ = ensure_subprocess_alive_best_effort(agent_uri, tmpl)
          end

          {:ok, [agent_uri], %{fresh?: false}}

        :started ->
          # codex round-10 HIGH-2 + PR3 2026-05-24 cascade:
          # 1. Create per-agent config_dir BEFORE PTY launch (so the
          #    cc process gets `CLAUDE_CONFIG_DIR=<per-agent-dir>`
          #    immediately).
          # 2. If config_dir creation fails → terminate the freshly-
          #    started Agent Kind (rollback what we created), return
          #    error.
          # 3. Thread `agent_config_dir` into `tmpl` so `build_claude_cmd/3`
          #    reads the PER-AGENT dir (not the template's reference
          #    dir).
          # 4. If `ensure_pty_server/3` fails → terminate the Kind AND
          #    remove the just-created config_dir (full rollback).
          # 5. On full success: return `config_dir_path: dir` AND
          #    `respawn_template_data: tmpl_with_dir` in meta so caller
          #    dispatches `sandbox.write_path` with both. The persisted
          #    respawn data lets Sandbox.post_init/2 call back into
          #    `ensure_subprocess_alive/2` on a phx restart
          #    (PTY-orphan-restart 2026-05-26).
          #
          # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B —
          # for role=orchestrator, ALSO load the
          # `ezagent-session-orchestrator` skill into the per-agent
          # config dir (`apply_orchestrator_role_bootstrap/2`) BEFORE
          # PTY launch so claude reads it from `CLAUDE_CONFIG_DIR` on
          # its first start. Idempotent (re-copies / re-appends only if
          # absent).
          #
          # codex PR #408 review HIGH-3 — role-bootstrap is BEST-EFFORT UX:
          # a skill-copy / CLAUDE.md-append failure DOES NOT tear down the
          # agent. The agent still spawns as a plain cc agent; the
          # degraded status surfaces structurally in meta (`role_degraded`)
          # so the caller (Session.ensure_orchestrator) can notify the
          # session owner per Invariant #9 (no silent drops at user-facing
          # surfaces). A telemetry event also fires so monitoring picks up
          # the failure independent of caller wiring. The PTY itself MUST
          # still come up — only role-bootstrap is best-effort, the rest
          # (config_dir, PTY) stays load-bearing.
          with {:ok, config_dir, grant_ctx} <- create_agent_config_dir_with_grant(agent_uri, tmpl),
               tmpl_with_dir = put_agent_config_dir(tmpl, config_dir),
               {:ok, role_meta} <- try_role_bootstrap(tmpl_with_dir, config_dir, agent_uri),
               # #17 cascade PR-2 (codex CRITICAL §5.1) — the config_dir is materialized
               # but the subprocess launches HERE (ensure_pty_server). A grant revoked
               # between materialize and launch would otherwise launch with the copied
               # secret. Re-validate the grant version IMMEDIATELY before launch; on
               # :grant_changed ABORT + clear the just-materialized config_dir so it is
               # not left usable for the revoked grant. No-grant agents skip this (nil ctx).
               :ok <- revalidate_grant_before_launch(grant_ctx),
               :ok <- ensure_pty_server(agent_uri, cwd, tmpl_with_dir) do
            base_meta = %{
              fresh?: true,
              config_dir_path: config_dir,
              respawn_template_data: tmpl_with_dir
            }

            {:ok, [agent_uri], Map.merge(base_meta, role_meta)}
          else
            {:error, reason} ->
              _ = Ezagent.Kind.terminate(agent_uri)
              handle_spawn_failure(agent_uri, reason)
          end
      end
    end
  end

  defp put_agent_config_dir(tmpl, dir),
    do: Ezagent.Credential.HomeRuntime.put_agent_config_dir(tmpl, dir)

  # #17 cascade PR-2 (codex CRITICAL §5.1) — normalize `create_agent_config_dir/2`'s
  # backward-compatible 2-tuple (non-cascade, no grant) and 3-tuple (cascade, carrying the
  # validated grant context) into a single `{:ok, dir, grant_ctx}` for the spawn path.
  defp create_agent_config_dir_with_grant(agent_uri, tmpl) do
    reject_stale_config_dir_data_key!(tmpl)

    Ezagent.Credential.HomeRuntime.create_agent_config_dir_with_grant(
      agent_uri,
      tmpl,
      __MODULE__,
      config_home_opts()
    )
  end

  # #17 cascade PR-2 (codex CRITICAL §5.1) — second grant re-validation, run IMMEDIATELY
  # before the subprocess launch (the config_dir was already swapped at materialize; the
  # launch is a LATER, distinct boundary). `nil` ctx (no-grant / non-cascade agents) → :ok.
  # On `:grant_changed` the caller's `else` clause tears down the Kind AND clears the
  # just-materialized config_dir (rollback_agent_config_dir), so nothing launches with — or
  # leaves usable — the secret of a now-revoked/changed grant.
  defp revalidate_grant_before_launch(grant_ctx),
    do: Ezagent.Credential.HomeRuntime.revalidate_grant_before_launch(grant_ctx)

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
  @spec apply_orchestrator_role_bootstrap(map(), String.t() | nil) ::
          :ok | {:error, term()}
  def apply_orchestrator_role_bootstrap(tmpl, config_dir) do
    Ezagent.PluginCc.Template.OrchestratorBootstrap.bootstrap(tmpl, config_dir)
  end

  # codex PR #408 review HIGH-3 — wrap `apply_orchestrator_role_bootstrap/2`
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
  @spec orchestrator_role?(map()) :: boolean()
  def orchestrator_role?(tmpl),
    do: Ezagent.PluginCc.Template.OrchestratorBootstrap.orchestrator_role?(tmpl)

  # Resolve the on-disk source of the `ezagent-session-orchestrator`
  # skill. Defaults to walking upward from this plugin's priv_dir looking
  # for the first ancestor that contains
  # `.claude/skills/ezagent-session-orchestrator/SKILL.md`. Override via
  # `config :ezagent_plugin_cc, :orchestrator_skill_source, "/abs/path"`
  # — used by tests to point at a temp fixture without touching the real
  # umbrella file.
  #
  # codex PR #408 review HIGH-2 — pre-fix used `Path.expand("../../../..", priv)`
  # which is 4 segments and lands at `<repo>/_build/.claude/...` (off by
  # one — the test env masked it via the app-env override). A hardcoded
  # `..` count is brittle and silently breaks when the priv-path depth
  # changes (e.g. release builds nest differently). The walk searches for
  # the actual `.claude/skills/...` marker so it is robust to depth
  # changes, and explicitly returns the list of attempted paths on
  # failure so operators can diagnose a missing-skill deployment.
  @doc false
  @spec resolve_orchestrator_skill_source() :: {:ok, String.t()} | {:error, term()}
  def resolve_orchestrator_skill_source do
    Ezagent.PluginCc.Template.OrchestratorBootstrap.resolve_orchestrator_skill_source()
  end

  @doc false
  @spec search_orchestrator_skill_source_from(String.t()) ::
          {:ok, String.t()} | {:error, {:skill_source_not_found, [String.t()]}}
  def search_orchestrator_skill_source_from(start_dir) when is_binary(start_dir) do
    Ezagent.PluginCc.Template.OrchestratorBootstrap.search_orchestrator_skill_source_from(
      start_dir
    )
  end

  @doc """
  The CLAUDE.md hint line appended for orchestrator-role cc agents.
  Public so tests can assert exact content (SPEC Gap B B2 / B4).
  """
  @spec orchestrator_hint_line() :: String.t()
  def orchestrator_hint_line, do: Ezagent.PluginCc.Template.OrchestratorBootstrap.hint_line()

  # codex H2 (FINDING 2) — handle a spawn failure AFTER the config_dir was materialized:
  # tear down the just-materialized config_dir, then SURFACE a cleanup failure as BLOCKING.
  #
  # The dir holds the grant-scoped secret. When the spawn aborts because the grant was
  # revoked at launch (`:grant_changed_before_launch`) and the cleanup `rm_rf` ALSO fails,
  # the secret dir is left in the canonical location. Reporting only the grant-change would
  # silently leave a usable revoked-grant credential dir on disk. Instead we return a
  # COMPOSITE `{:grant_revoked_cleanup_failed, agent_uri, reason}` so the leftover secret is
  # surfaced as blocking. For any OTHER failure where cleanup also fails we attach the
  # cleanup failure too (never silently leave a half-materialized dir while reporting only
  # the primary error).
  #
  # `@doc false` (not truly public API) so the spawn-failure cleanup contract is directly
  # unit-testable with an injected rm_rf failure.
  @doc false
  @spec handle_spawn_failure(URI.t(), term()) :: {:error, term()}
  def handle_spawn_failure(agent_uri, reason) do
    Ezagent.Credential.HomeRuntime.handle_spawn_failure(agent_uri, reason, __MODULE__, "cc.agent")
  end

  # codex round-6 HIGH-1 — `SpawnRegistry.spawn_detailed/1` preserves
  # the atomic `DynamicSupervisor` outcome: exactly one concurrent
  # caller gets `:started`, every other gets `:already_started`. This
  # is the ground-truth freshness signal — NOT a pre-probe (a pre-probe
  # is a TOCTOU window). Returns `{:ok, :started | :already_started}`.
  defp ensure_agent_kind(agent_uri) do
    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, _pid} ->
        {:ok, :started}

      {:ok, :already_started, _pid} ->
        # Atomic dedup at KindRegistry / supervisor level — the Kind was
        # spawned by a concurrent caller (or by an earlier instantiate
        # that crashed between Kind spawn and PtyServer start). Still a
        # success, but THIS call did not create the worker.
        {:ok, :already_started}

      {:error, reason} ->
        Logger.warning(
          "cc.agent: SpawnRegistry.spawn_detailed failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:agent_kind_spawn_failed, reason}}
    end
  end

  defp ensure_pty_server(agent_uri, cwd, tmpl) do
    Ezagent.PluginCc.Template.SpawnPlan.ensure_pty_server(agent_uri, cwd, tmpl, @compile_env)
  end

  @doc false
  def build_pty_params(agent_uri, cwd, tmpl) do
    Ezagent.PluginCc.Template.SpawnPlan.build_pty_params(agent_uri, cwd, tmpl, @compile_env)
  end

  @doc false
  def build_pty_params_for_env(agent_uri, cwd, tmpl, env) do
    Ezagent.PluginCc.Template.SpawnPlan.build_pty_params_for_env(agent_uri, cwd, tmpl, env)
  end

  @doc false
  def build_claude_cmd(agent_uri, agent_cwd, tmpl) do
    Ezagent.PluginCc.Template.SpawnPlan.build_claude_cmd(agent_uri, agent_cwd, tmpl)
  end

  @doc false
  @spec resolve_claude_executable(URI.t()) :: {:ok, String.t()} | {:error, :claude_not_found}
  def resolve_claude_executable(agent_uri) do
    Ezagent.PluginCc.Template.SpawnPlan.resolve_claude_executable(agent_uri)
  end

  # PR-3 (DD-6 + codex review P2) — the resolved per-agent config home: the single
  # value used for BOTH `CLAUDE_CONFIG_DIR` and the authoritative `--mcp-config`
  # `.mcp.json`. Precedence:
  #   1. realized `agent_config_dir` (threaded at fresh create / persisted respawn);
  #   2. `allocated_config_dir` (the domain-allocated TARGET injected by
  #      `provision_and_instantiate/4` — present on the `:already_started`
  #      PTY-recovery path that skips `create_agent_config_dir/2`);
  #   3. a `config_dir` REFERENCE is present (the agent HAS a config home) but
  #      neither realized nor allocated key is in tmpl → DERIVE the per-agent
  #      target from the agent URI. **Never** the shared template reference dir —
  #      that would write per-agent files into the shared source (codex P2,
  #      `feedback_let_it_crash_no_workarounds`: no shared-fallback);
  #   4. no reference → nil (no config home; claude uses ~/.claude).
  @doc false
  def resolve_config_home(%URI{} = agent_uri, tmpl) do
    Ezagent.Credential.HomeRuntime.resolve_config_home(agent_uri, tmpl, __MODULE__)
  end

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
  def assemble_settings_mcp_args(mandatory_settings_path, bridge_mcp_path, tmpl)
      when is_binary(mandatory_settings_path) and is_binary(bridge_mcp_path) and is_map(tmpl) do
    Ezagent.PluginCc.Template.SpawnPlan.assemble_settings_mcp_args(
      mandatory_settings_path,
      bridge_mcp_path,
      tmpl
    )
  end

  defp agent_kind_alive?(agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} -> true
      :error -> false
    end
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
  # teardown by `Ezagent.Behavior.Sandbox.invoke(:destroy, ...)`.
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
  # Invoked by `Ezagent.Behavior.Sandbox`'s post_init/2 continuation
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
          cond do
            # #17 cascade PR-2 (§5.1) — a (re)start is a cascade boundary: an agent whose
            # credential grant was REVOKED must NOT come back up holding stale creds. An agent
            # with an ACTIVE grant or with NO grant at all (existing pre-cascade agents) is
            # unaffected. This is the safe, contained slice of the §5.1 "restart then
            # fails-or-re-resolves" rule; the FULL re-resolve-from-inputs re-materialize is
            # FLAGGED (see moduledoc / report) as PR-3-coordinated.
            grant_revoked_for_restart?(agent_uri) ->
              {:error, {:credential_grant_revoked, agent_uri}}

            true ->
              # PtyServer absent — rebuild it from the persisted respawn data.
              # `cwd` is required in respawn_data per `check_cwd/1`; the rest
              # of the keys are optional and may carry the agent_config_dir
              # added at spawn-time (so we don't recreate the config dir
              # here — the snapshot is the source of truth for it).
              case Map.fetch(respawn_data, "cwd") do
                {:ok, cwd} when is_binary(cwd) and cwd != "" ->
                  case ensure_pty_server(agent_uri, cwd, respawn_data) do
                    :ok ->
                      Logger.info(
                        "cc.agent.ensure_subprocess_alive: respawned PtyServer for " <>
                          URI.to_string(agent_uri)
                      )

                      # 2026-05-31 orchestrator-startup-atomicity §5 — for an
                      # ORCHESTRATOR boot respawn, readiness = REGISTERED, not
                      # process-alive. Await the same live-join gate (staggered
                      # so N orchestrators don't each block 30s simultaneously);
                      # on timeout fail-loud (returns `{:error, _}` → Sandbox
                      # logs + telemetry `:subprocess_unhealthy` + stops the
                      # respawn — the operator restarts via /admin). Test-mode
                      # skips the live wait (no real claude to JOIN). A non-
                      # orchestrator cc agent has no registration gate (out of
                      # scope per SPEC §10) → `:ok` immediately.
                      await_orchestrator_boot_readiness(agent_uri, respawn_data)

                    {:error, reason} = err ->
                      Logger.error(
                        "cc.agent.ensure_subprocess_alive: failed to respawn PtyServer for " <>
                          "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
                      )

                      err
                  end

                _ ->
                  {:error, {:missing_cwd_in_respawn_data, agent_uri}}
              end
          end
        end
    end
  end

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  # #17 cascade PR-2 (§5.1) — true iff this agent has a credential grant that is now
  # REVOKED. An agent with no grant row (existing pre-cascade agents) or an active grant
  # returns false (proceed). Defensive: a DB error here must not crash-loop the boot of
  # an agent whose grant state we can't read — treat as "not provably revoked" and let
  # the materialize-time TOCTOU gate be the loud authority. (Cold restart does not
  # re-materialize secrets in this PR, so the running creds stay until a real
  # re-materialize — see the FLAGGED full-re-resolve note.)
  defp grant_revoked_for_restart?(%URI{} = agent_uri),
    do: Ezagent.Credential.HomeRuntime.grant_revoked_for_restart?(agent_uri)

  # 2026-05-31 orchestrator-startup-atomicity §5 — orchestrator boot
  # readiness gate. Mirrors `Session.ensure_orchestrator/3`'s create-time
  # gate, on the BOOT respawn path: a respawned orchestrator PTY is only
  # READY once its live claude's MCP bridge JOINs + registers (broadcast
  # on `"orch:lifecycle"`). Until then it is a non-functional zombie that
  # would retry the bridge JOIN forever.
  #
  # Bounded-concurrency STAGGER: on a multi-orchestrator boot, having
  # every Kind's `activate/2` block 30s simultaneously is an N×30s boot
  # storm. We serialize the WAITS through `@orch_boot_gate_slots`
  # `:global.trans` lock slots (slot = `phash2(uri) rem N`) so at most N
  # gates wait concurrently; the rest queue behind a slot.
  @orchestrator_boot_readiness_timeout_ms 30_000
  @orch_boot_gate_slots 4

  defp await_orchestrator_boot_readiness(%URI{} = agent_uri, respawn_data) do
    cond do
      not orchestrator_role?(respawn_data) ->
        # Non-orchestrator cc agent — no registration gate (SPEC §10 out).
        :ok

      orchestrator_gate_test_mode?() ->
        # No live claude in test_mode → no bridge JOIN → the gate would
        # always time out. The synchronous registration is the test's
        # readiness; skip the live wait.
        :ok

      true ->
        with_orch_boot_gate_slot(agent_uri, fn ->
          do_await_orchestrator_boot_readiness(agent_uri)
        end)
    end
  end

  # Run `fun` while holding one of N global gate slots — bounds the number
  # of concurrent 30s waits across all booting orchestrators. `:global.trans`
  # blocks until the slot lock is acquired (FIFO-ish), then releases it
  # when `fun` returns.
  defp with_orch_boot_gate_slot(%URI{} = agent_uri, fun) when is_function(fun, 0) do
    slot = :erlang.phash2(URI.to_string(agent_uri), @orch_boot_gate_slots)
    lock_id = {{:ezagent_orch_boot_gate, slot}, self()}
    :global.trans(lock_id, fun)
  end

  # Subscribe-then-check-then-wait. We subscribe to `"orch:lifecycle"`
  # FIRST, then check whether the orchestrator is ALREADY registered
  # (the bridge may have joined during the PTY respawn / slot wait); if so
  # we are done. Otherwise `receive` the readiness signal ≤30s. On timeout
  # fail-loud.
  defp do_await_orchestrator_boot_readiness(%URI{} = agent_uri) do
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, orch_lifecycle_topic())

    if orchestrator_registered?(agent_uri) do
      _ = Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, orch_lifecycle_topic())
      :ok
    else
      receive_orchestrator_boot_ready(agent_uri)
    end
  end

  defp receive_orchestrator_boot_ready(%URI{} = agent_uri) do
    receive do
      {:orchestrator_ready, %URI{} = ready_uri} ->
        if URI.to_string(ready_uri) == URI.to_string(agent_uri) do
          _ = Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, orch_lifecycle_topic())
          :ok
        else
          receive_orchestrator_boot_ready(agent_uri)
        end
    after
      @orchestrator_boot_readiness_timeout_ms ->
        _ = Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, orch_lifecycle_topic())

        Logger.error(
          "cc.agent.ensure_subprocess_alive: orchestrator #{URI.to_string(agent_uri)} did " <>
            "NOT register within #{@orchestrator_boot_readiness_timeout_ms}ms on boot respawn " <>
            "— failing loud (Sandbox stops the respawn; operator restarts via /admin)."
        )

        {:error, {:orchestrator_not_ready_within, @orchestrator_boot_readiness_timeout_ms}}
    end
  end

  # The lifecycle topic string. Hard-coded here (NOT a call into
  # `Ezagent.Orchestrator.McpChannel.lifecycle_topic/0`) because
  # `ezagent_domain_instance_message` is a `only: :test` dep of this plugin — it is
  # NOT a compile dep in prod. The topic is a stable string contract
  # shared with `McpChannel.join/3`'s broadcast (§5); a drift would be
  # caught by the live e2e (the only validator of the live gate).
  defp orch_lifecycle_topic, do: "orch:lifecycle"

  # Registered? = `Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1`
  # resolves. Runtime-guarded `apply` (NOT a direct module ref) for the
  # same `only: :test` dep reason as `orch_lifecycle_topic/0`: the module
  # IS loaded at runtime (chat boots in the umbrella) but referencing it
  # at compile time would break this plugin's prod build. A not-loaded
  # module (impossible in the running umbrella, but defensive) → not
  # registered → fall through to the live wait.
  defp orchestrator_registered?(%URI{} = agent_uri) do
    mod = Ezagent.Orchestrator.McpServer

    if Code.ensure_loaded?(mod) and function_exported?(mod, :from_orchestrator_uri, 1) do
      match?({:ok, _}, apply(mod, :from_orchestrator_uri, [agent_uri]))
    else
      false
    end
  end

  # test_mode = compile-time `:test` — same rationale as the create-time
  # gate (cc PtyServer short-circuits real claude in `:test`). Keep the
  # compile-time check for release-safety, with a guarded runtime fallback
  # for precommit/app-start paths that can recompile before tests run.
  defp orchestrator_gate_test_mode? do
    @compile_env == :test or (Code.ensure_loaded?(Mix) and Mix.env() == :test)
  end

  # Cross-workspace adoption gate (codex round-2 finding #1). We only
  # bring up a PTY for an already-started Kind when the agent URI's
  # workspace segment matches the workspace we're being instantiated
  # into. A mismatch means "another workspace's template is referencing
  # our URI" — we must refuse (preserves codex round-8 invariant).
  defp owns_this_agent?(%URI{} = agent_uri, %URI{} = workspace_uri) do
    case {Ezagent.URI.type(agent_uri), Ezagent.URI.workspace_name(agent_uri)} do
      {{:ok, "agent"}, {:ok, ws_segment}} -> ws_segment == workspace_uri.host
      _ -> false
    end
  end

  # When workspace_uri is nil (legacy callers that don't thread it),
  # default to false — preserves the codex round-8 invariant for
  # callers that don't know about the round-2 fix.
  defp owns_this_agent?(_agent_uri, nil), do: false
  defp owns_this_agent?(_, _), do: false

  # Wrapper for `instantiate/3`'s `:already_started` branch (codex
  # round-2 finding #1). Calls `ensure_subprocess_alive/2` but never
  # propagates its error — the adopted-Kind path's invariant is "this
  # call did not create the Kind, so we don't tear it down on
  # subprocess failure either". A failed PTY respawn leaves the Kind
  # alive but degraded; operator sees the failure via logs/health
  # panel and clicks Restart manually.
  defp ensure_subprocess_alive_best_effort(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    case ensure_subprocess_alive(agent_uri, tmpl) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "cc.agent.instantiate(:already_started): ensure_subprocess_alive failed for " <>
            "#{URI.to_string(agent_uri)} (#{inspect(reason)}); Kind remains alive in " <>
            "degraded state (no PTY) — operator may need to Restart manually"
        )

        {:error, reason}
    end
  end

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

    Ezagent.Credential.HomeRuntime.create_agent_config_dir(
      agent_uri,
      tmpl,
      __MODULE__,
      config_home_opts()
    )
  end

  defp config_home_opts, do: [stage_error_tag: :copy_reference_dir_failed, chmod_error: :bare]

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

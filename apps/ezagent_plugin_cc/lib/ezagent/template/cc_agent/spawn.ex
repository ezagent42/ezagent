defmodule Ezagent.PluginCc.Template.CcAgent.Spawn do
  @moduledoc """
  Spawn / PTY / grant-cascade machinery extracted VERBATIM from
  `Ezagent.PluginCc.Template.CcAgent` (PR-3T, #25 Phase-3 burn-down,
  2026-06-09 — `gt_1000` 3 → 2).

  This module is a pure RELOCATION of the cc create-chokepoint +
  #17/#641 credential-cascade materialization machinery. The bodies are
  char-identical to their pre-extraction form on `CcAgent`; the ONLY edits
  are the mechanical qualifications a relocation requires:

    * Calls to functions that STAYED on `CcAgent` are qualified with the
      `CcAgent` alias (`try_role_bootstrap/3`, `handle_spawn_failure/2`,
      `ensure_subprocess_alive/2`, `orchestrator_role?/1`,
      `reject_stale_config_dir_data_key!/1`).
    * The two `__MODULE__` references inside `create_agent_config_dir_with_grant/2`
      are the **CredentialAdapter identity** the cascade keys on — they MUST
      remain `Ezagent.PluginCc.Template.CcAgent` (NOT `__MODULE__`, which would
      now resolve to this Spawn module and silently break the cascade). They are
      written out explicitly here.

  No grant / cascade / authorization logic was touched. The
  `@impl instantiate/3` and `@impl ensure_subprocess_alive/2` callbacks remain
  on `CcAgent` (the Template engine dispatches by module) and delegate the
  spawn-orchestration steps into this module.
  """

  alias Ezagent.PluginCc.Template.CcAgent

  require Logger

  # Compile-time env capture. `Mix.env()` is NOT available in a compiled
  # release (Mix is not loaded — see migration_gate.ex), so calling it at
  # runtime would crash the orchestrator PTY spawn path. The deployment env
  # is fixed at compile time, so a module attribute is both release-safe and
  # correct. (codex final-review Q1.)
  @compile_env Mix.env()

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
  def spawn_for_local_pty(agent_uri, tmpl, workspace_uri) do
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
               {:ok, role_meta} <-
                 CcAgent.try_role_bootstrap(tmpl_with_dir, config_dir, agent_uri),
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
    CcAgent.reject_stale_config_dir_data_key!(tmpl)

    Ezagent.Credential.HomeRuntime.create_agent_config_dir_with_grant(
      agent_uri,
      tmpl,
      Ezagent.PluginCc.Template.CcAgent,
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

  @doc """
  Grant-guarded PTY respawn entrypoint for the cold-restart / orphan-restart
  path. The ONLY public way to reach the raw PTY launcher on respawn: it runs
  the credential-grant revocation boundary (#17 cascade §5.1) BEFORE launch,
  so `ensure_pty_server/3` stays PRIVATE and the cc create-chokepoint cannot be
  bypassed by an in-process caller (codex PR-3T review HIGH).
  """
  def respawn_subprocess(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    cond do
      # #17 cascade PR-2 (§5.1) — a (re)start is a cascade boundary: an agent whose
      # credential grant was REVOKED must NOT come back up holding stale creds. An agent
      # with an ACTIVE grant or with NO grant at all (existing pre-cascade agents) is
      # unaffected.
      grant_revoked_for_restart?(agent_uri) ->
        {:error, {:credential_grant_revoked, agent_uri}}

      true ->
        # `cwd` is required in respawn_data per `check_cwd/1`; the rest of the keys
        # are optional and may carry the agent_config_dir added at spawn-time (so we
        # don't recreate the config dir here — the snapshot is the source of truth).
        case Map.fetch(respawn_data, "cwd") do
          {:ok, cwd} when is_binary(cwd) and cwd != "" ->
            # §5.B follow-up (c) — re-provision the SOURCE agent's credential on its
            # OWN respawn. The fresh-create path provisions the source's
            # `.credentials.json` via the test/E2E refresh-if-expired provisioner;
            # respawn deliberately does NOT re-materialize the config_dir, so before
            # this fix an OAuth token that expired between create and respawn stayed
            # expired and the source came back up mute. When respawn_data carries an
            # E2E `:credential_source` (production interactive-login agents never set
            # it), re-run the provisioner into the resolved config_home BEFORE
            # relaunch so the source's credential is DURABLE across its own restarts.
            # Best-effort: a missing/failed E2E source must not crash-loop the respawn
            # (the agent's own auth-failure observers surface a truly-dead cred).
            _ = maybe_reprovision_source_from_respawn_data(agent_uri, respawn_data)

            case ensure_pty_server(agent_uri, cwd, respawn_data) do
              :ok ->
                Logger.info(
                  "cc.agent.ensure_subprocess_alive: respawned PtyServer for " <>
                    URI.to_string(agent_uri)
                )

                # orchestrator-startup-atomicity §5 — orchestrator boot respawn
                # readiness = REGISTERED, not process-alive. Non-orchestrator cc
                # agents return :ok immediately.
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

  # §5.B follow-up (c) — respawn-time SOURCE credential re-provisioning.
  #
  # Reads the E2E `:credential_source` from respawn_data (atom or string key). When
  # present, resolves the agent's config_home from respawn_data and re-runs the
  # refresh-if-expired provisioner into it. Absent key / unresolvable config_home →
  # no-op (the production interactive-login path never sets the key). A provisioner
  # FAILURE is logged + swallowed (best-effort — a missing/expired E2E source must
  # not crash-loop the source agent's respawn; its own PTY auth-failure observers
  # surface a genuinely-dead credential).
  @doc false
  @spec maybe_reprovision_source_from_respawn_data(URI.t(), map()) :: :ok
  def maybe_reprovision_source_from_respawn_data(%URI{} = agent_uri, respawn_data)
      when is_map(respawn_data) do
    case credential_source_field(respawn_data) do
      nil ->
        :ok

      source_path when is_binary(source_path) ->
        config_home = resolve_config_home(agent_uri, respawn_data)

        case reprovision_source_credential(config_home, source_path, []) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "cc.agent: source-credential re-provision on respawn failed for " <>
                "#{URI.to_string(agent_uri)} (source=#{source_path}): #{inspect(reason)} — " <>
                "the agent will relaunch with whatever credential is on disk; its PTY " <>
                "auth-failure observers surface a dead credential. (best-effort, §5.B c)"
            )

            :ok
        end
    end
  end

  defp credential_source_field(respawn_data) do
    case Map.get(respawn_data, "credential_source") || Map.get(respawn_data, :credential_source) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  # The refresh-if-expired provisioner (TEST/E2E only). `nil` config_home or
  # `nil`/blank source → no-op. Delegates to the cc CredentialAdapter so the OAuth
  # `http_post` + clock are injectable by tests (no network, no real-token rotation).
  @doc false
  @spec reprovision_source_credential(String.t() | nil, String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def reprovision_source_credential(nil, _source, _opts), do: :ok
  def reprovision_source_credential(_config_home, nil, _opts), do: :ok
  def reprovision_source_credential(_config_home, "", _opts), do: :ok

  def reprovision_source_credential(config_home, source, opts)
      when is_binary(config_home) and is_binary(source) do
    CcAgent.refresh_test_credentials(source, config_home, opts)
  end

  # Raw cc PTY launcher — PRIVATE (codex PR-3T/#701 chokepoint): reachable
  # only via the grant-gated `spawn_for_local_pty/3` (fresh spawn) and
  # `respawn_subprocess/2` (cold restart), never directly. It builds the cc
  # launch params (SpawnPlan, build-only) THEN starts the PTY — the
  # `Ezagent.Domain.Pty.start/2` launch lives HERE behind the gate, not in
  # the public SpawnPlan builder, so a cc PTY can never start without the
  # credential-grant gate (#701 hardening of the SpawnPlan public-launcher
  # bypass).
  defp ensure_pty_server(agent_uri, cwd, tmpl) do
    with {:ok, params} <-
           Ezagent.PluginCc.Template.SpawnPlan.build_pty_params(
             agent_uri,
             cwd,
             tmpl,
             @compile_env
           ),
         {:ok, _pid} <- start_pty(agent_uri, params) do
      :ok
    end
  end

  defp start_pty(agent_uri, params) do
    case Ezagent.Domain.Pty.start(agent_uri, params) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning(
          "cc.agent: PtyServer start failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:pty_server_spawn_failed, reason}}
    end
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
  # PR-3T — the adapter identity passed to `HomeRuntime` MUST remain
  # `Ezagent.PluginCc.Template.CcAgent` (NOT `__MODULE__`, which now resolves to
  # this Spawn module).
  @doc false
  def resolve_config_home(%URI{} = agent_uri, tmpl) do
    Ezagent.Credential.HomeRuntime.resolve_config_home(
      agent_uri,
      tmpl,
      Ezagent.PluginCc.Template.CcAgent
    )
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

  @doc false
  def config_home_opts, do: [stage_error_tag: :copy_reference_dir_failed, chmod_error: :bare]

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
  # unit-testable with an injected rm_rf failure. The adapter identity passed to
  # `HomeRuntime` MUST remain `Ezagent.PluginCc.Template.CcAgent` (NOT `__MODULE__`, which
  # now resolves to this Spawn module) — the credential cascade keys on it.
  @doc false
  @spec handle_spawn_failure(URI.t(), term()) :: {:error, term()}
  def handle_spawn_failure(agent_uri, reason) do
    Ezagent.Credential.HomeRuntime.handle_spawn_failure(
      agent_uri,
      reason,
      Ezagent.PluginCc.Template.CcAgent,
      "cc.agent"
    )
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
    case CcAgent.ensure_subprocess_alive(agent_uri, tmpl) do
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
      not CcAgent.orchestrator_role?(respawn_data) ->
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
end

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
      `ensure_subprocess_alive/2`, `orchestrator_recipe?/1`,
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

  # Phase 3 ③ T7h — transport-join gate timeout, now operator-configurable.
  # The cc ReadyGate flips `:ready` only AFTER the claude sidecar JOINs the
  # bridge (PTY → claude → esr-bridge MCP → channel bind, via
  # `Ezagent.Agent.TransportReadiness`). On a loaded host claude cold-start to
  # JOIN measured 50–85s, well past this default — so the gate fired
  # `mark_failed` before readiness and rolled the spawn back. Keep the default
  # at the historical 30s (no behavior change) but let operators / e2e raise it
  # via `config :ezagent_plugin_cc, :transport_join_timeout_ms, <ms>`.
  # SURFACE (Allen): 30s is generally tight for cc cold-start under load — a
  # higher default (or a documented requirement to configure it) may be
  # warranted; left to Allen's budget call. See t7b-evidence act4 发现 1.
  @default_transport_join_timeout_ms 30_000

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
  @doc false
  def spawn_for_local_pty(agent_uri, tmpl, workspace_uri, opts \\ []) do
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
    # calling `ensure_pty_server/4`. Starting a PTY / `claude` sidecar
    # for a pre-existing (possibly foreign or orphaned) worker would
    # make a rejected adoption non-zero-side-effect. The Template Class
    # only brings up a sidecar for a worker IT freshly started; whether
    # to adopt a pre-existing worker is the caller's decision.
    config_dir = resolve_config_home(agent_uri, tmpl)

    tmpl_with_dir =
      tmpl
      |> put_agent_config_dir(config_dir)
      |> Map.put_new("flavor", "cc")

    with {:ok, started_or_adopted} <-
           ensure_agent_kind(agent_uri, config_dir, tmpl_with_dir, opts) do
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
          if Ezagent.Agent.Ownership.workspace_match?(agent_uri, workspace_uri) do
            _ = ensure_subprocess_alive_best_effort(agent_uri, tmpl)
          end

          {:ok, [agent_uri], %{fresh?: false}}

        {:started, false, _witness} ->
          # #201 PR-3 — REHYDRATING winner (`:started ∧ ¬created?`): this call
          # won the process start, but the agent was logically created BEFORE
          # (a cold, durably pre-existing agent — e.g. hit by a duplicate-create
          # carrying a credential source). ZERO credential writes here: NO
          # grant-scoped materialization (the config dir on disk is the agent's
          # own pre-existing one; re-materializing would inject THIS attempt's
          # source) and NO grant keep (the chokepoint deletes this attempt's
          # minted grant incarnation). The Kind's own `Sandbox.post_init`
          # self-heals the subprocess from the DURABLE respawn state.
          # `fresh?: true` stays: the chokepoint needs the `:started` signal
          # for the idempotent flavor/obligations self-heal. No
          # `:config_dir_path` in meta → `record_sandbox_state` preserves the
          # existing slice verbatim.
          {:ok, [agent_uri], %{fresh?: true, created?: false}}

        {:started, true, created_witness} ->
          # codex round-10 HIGH-2 + PR3 2026-05-24 cascade:
          # 1. Create per-agent config_dir BEFORE PTY launch (so the
          #    cc process gets `CLAUDE_CONFIG_DIR=<per-agent-dir>`
          #    immediately). #201-cred (codex r2 HIGH-1) — the credential
          #    grant is MINTED inside this step (the deferred-mint boundary:
          #    this arm is the created-winner, receipt already in hand).
          # 2. If config_dir creation fails → terminate the freshly-
          #    started Agent Kind (rollback what we created), return
          #    error.
          # 3. Thread `agent_config_dir` into `tmpl` so `build_claude_cmd/3`
          #    reads the PER-AGENT dir (not the template's reference
          #    dir).
          # 4. If ANY post-materialize step fails (role bootstrap / grant
          #    revalidation / PTY) → terminate the Kind, CONFIRM-compensate
          #    exactly the minted grant incarnation (never best-effort),
          #    AND remove the just-created config_dir (full rollback).
          # 5. On full success: return `config_dir_path: dir`,
          #    `respawn_template_data: tmpl_with_dir`, and the mint receipt
          #    `:grant_incarnation_id` (the chokepoint's rollback compensates
          #    EXACTLY that incarnation on a post-instantiate obligation
          #    failure). The persisted respawn data lets Sandbox.post_init/2
          #    call back into `ensure_subprocess_alive/2` on a phx restart
          #    (PTY-orphan-restart 2026-05-26).
          #
          # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B —
          # for role=orchestrator, ALSO load the
          # `ezagent-session-orchestrator` skill into the per-agent
          # config dir (`apply_orchestrator_recipe_bootstrap/2`) BEFORE
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
          # #201-cred (codex r2 NEW-HIGH-3) — inject the created-winner witness
          # from THIS `:started ∧ created?` receipt into the cascade map so the
          # deferred mint in `HomeRuntime.materialize_cascade/6` can prove it is
          # on the created-winner arm (`GrantMint` fail-closes without it).
          tmpl_for_materialization =
            tmpl
            |> materialization_template(agent_uri)
            |> Ezagent.Credential.HomeRuntime.put_cascade_created_witness(created_witness)

          case create_agent_config_dir_with_grant(agent_uri, tmpl_for_materialization) do
            {:ok, materialized_config_dir, grant_ctx} ->
              tmpl_with_dir =
                tmpl_for_materialization
                |> put_agent_config_dir(materialized_config_dir)
                |> Map.put_new("flavor", "cc")

              # #17 cascade PR-2 (codex CRITICAL §5.1) — the config_dir is materialized
              # but the subprocess launches HERE (ensure_pty_server). A grant revoked
              # between materialize and launch would otherwise launch with the copied
              # secret. Re-validate the grant incarnation IMMEDIATELY before launch; on
              # :grant_changed ABORT + clear the just-materialized config_dir so it is
              # not left usable for the revoked grant. No-grant agents skip this (nil ctx).
              launch_result =
                with {:ok, role_meta} <-
                       CcAgent.try_role_bootstrap(
                         tmpl_with_dir,
                         materialized_config_dir,
                         agent_uri
                       ),
                     :ok <- revalidate_grant_before_launch(grant_ctx),
                     # Fresh spawn → resume? = false (a brand-new agent has no prior
                     # conversation; `--continue` would only find nothing).
                     :ok <- ensure_pty_server(agent_uri, cwd, tmpl_with_dir, false) do
                  {:ok, role_meta}
                end

              case launch_result do
                {:ok, role_meta} ->
                  # #17 (c) — spawn-time OAuth freshness reminder. Best-effort, never
                  # blocks: surfaces `credential_stale` in meta (like `role_degraded`)
                  # + warns + telemetry when the materialized token is already expired,
                  # so the owner is told to re-login instead of the agent silently 401ing.
                  credential_meta =
                    EzagentPluginCc.CredentialFreshness.remind(
                      agent_uri,
                      materialized_config_dir
                    )

                  base_meta = %{
                    fresh?: true,
                    # #201 PR-1 — the core-issued logical-create verdict from the
                    # spawn receipt (`Ezagent.Kind.spawn_receipt/3`), passed through
                    # unmodified so the chokepoint can gate create-only writes
                    # (credential grant mint / materialization) on it. `:started`
                    # alone is NOT proof of logical create (a cold rehydrate wins
                    # `:started` with `created?: false` — handled by the arm above,
                    # which performs NO credential writes).
                    created?: true,
                    # #201-cred — the deferred-mint receipt: the chokepoint's
                    # rollback compensates EXACTLY this incarnation on a
                    # post-instantiate obligation failure (nil = no grant minted).
                    grant_incarnation_id:
                      Ezagent.Credential.HomeRuntime.grant_ctx_incarnation(grant_ctx),
                    config_dir_path: materialized_config_dir,
                    respawn_template_data: tmpl_with_dir
                  }

                  {:ok, [agent_uri],
                   base_meta |> Map.merge(role_meta) |> Map.merge(credential_meta)}

                {:error, reason} ->
                  _ = Ezagent.Kind.terminate!(agent_uri)
                  compensate_and_report(agent_uri, grant_ctx, reason)
              end

            {:error, reason} ->
              _ = Ezagent.Kind.terminate!(agent_uri)
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

  defp materialization_template(tmpl, agent_uri) do
    case CcAgent.attach_role_sandbox_content(tmpl, agent_uri) do
      {:ok, tmpl_with_sandbox_content} -> tmpl_with_sandbox_content
      {:error, _reason} -> tmpl
    end
  end

  # #17 cascade PR-2 (codex CRITICAL §5.1) — second grant re-validation, run IMMEDIATELY
  # before the subprocess launch (the config_dir was already swapped at materialize; the
  # launch is a LATER, distinct boundary). `nil` ctx (no-grant / non-cascade agents) → :ok.
  # On `:grant_changed` the caller's `else` clause tears down the Kind AND clears the
  # just-materialized config_dir (rollback_agent_config_dir), so nothing launches with — or
  # leaves usable — the secret of a now-revoked/changed grant.
  defp revalidate_grant_before_launch(grant_ctx),
    do: Ezagent.Credential.HomeRuntime.revalidate_grant_before_launch(grant_ctx)

  # #201-cred (codex r2 HIGH-2) — post-mint spawn failure: CONFIRM-compensate
  # exactly the minted grant incarnation, then the config-dir teardown (the
  # shared HomeRuntime path). The adapter identity MUST remain
  # `Ezagent.PluginCc.Template.CcAgent` (the credential cascade keys on it).
  defp compensate_and_report(agent_uri, grant_ctx, reason) do
    Ezagent.Credential.HomeRuntime.compensate_spawn_failure(
      agent_uri,
      grant_ctx,
      reason,
      Ezagent.PluginCc.Template.CcAgent,
      "cc.agent"
    )
  end

  # codex round-6 HIGH-1 — `Kind.spawn/2` preserves the atomic
  # `DynamicSupervisor` outcome: exactly one concurrent caller gets
  # `:started`, every other gets `:already_started`. This is the
  # ground-truth freshness signal — NOT a pre-probe (a pre-probe is a
  # TOCTOU window). Returns `{:ok, {:started, created?} | :already_started}`
  # where `created?` is the core-issued logical-create verdict from the
  # #201 PR-1 spawn receipt (`Ezagent.Kind.spawn_receipt/3`).
  #
  # AutoService cc-orchestrator materialization (2026-06-30): pass the
  # sandbox state as Agent Kind init args so `Sandbox.create/1` persists
  # `config_dir_path` + respawn data before bridge transport readiness can
  # hold the public ReadyGate at `:not_ready`. The config directory is still
  # materialized only after this call wins `:started`, preserving the
  # loser-does-not-touch-config-dir race invariant above.
  defp ensure_agent_kind(agent_uri, config_dir, tmpl_with_dir, opts) do
    init_args = %{
      uri: agent_uri,
      config_dir_path: config_dir,
      template_class: CcAgent,
      respawn_template_data: tmpl_with_dir
    }

    # derivation-edge: template-post-obligation TemplateSpawn records fresh workers
    case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, init_args, opts) do
      {:ok, :started, _pid, %{created?: created?} = receipt} ->
        # #201-cred (codex r2 NEW-HIGH-3) — carry the created-winner witness out
        # (nil for a rehydrating winner) so the `{:started, true}` arm can thread
        # it into the deferred mint.
        {:ok, {:started, created?, Map.get(receipt, :created_witness)}}

      {:ok, :already_started, _pid, _receipt} ->
        # Atomic dedup at KindRegistry / supervisor level — the Kind was
        # spawned by a concurrent caller (or by an earlier instantiate
        # that crashed between Kind spawn and PtyServer start). Still a
        # success, but THIS call did not create the worker.
        {:ok, :already_started}

      {:error, {:already_registered, _uri_or_pid}} ->
        # Direct `Kind.spawn/2` reports a live registry collision as
        # `:already_registered`; the previous LocalRuntime wrapper exposed
        # this adoption case as `:already_started`. Preserve that template
        # idempotency contract.
        {:ok, :already_started}

      {:error, reason} ->
        Logger.warning(
          "cc.agent: Kind.spawn failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:agent_kind_spawn_failed, reason}}
    end
  end

  @doc """
  Grant-guarded PTY respawn entrypoint for the cold-restart / orphan-restart
  path. The ONLY public way to reach the raw PTY launcher on respawn: it runs
  the credential-grant revocation boundary (#17 cascade §5.1) BEFORE launch,
  so `ensure_pty_server/4` stays PRIVATE and the cc create-chokepoint cannot be
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

            # cc-PTY hardening 2026-07-10 (audit #2): a respawn (crash / OOM /
            # cold restart) must RESUME the prior conversation, not start fresh.
            # resume? = true → the argv gets `--continue` (targets THIS agent's
            # conversation via its own cwd + CLAUDE_CONFIG_DIR).
            case ensure_pty_server(agent_uri, cwd, respawn_data, true) do
              :ok ->
                # #17 (c) — respawn is the cold-restart case where a day-old OAuth
                # token most often relaunches MUTE (respawn does NOT re-materialize
                # the config_dir). Best-effort reminder (warn + telemetry) so a dead
                # token is visible instead of silently 401ing. Never blocks.
                _ =
                  EzagentPluginCc.CredentialFreshness.remind(
                    agent_uri,
                    resolve_config_home(agent_uri, respawn_data)
                  )

                Logger.info(
                  "cc.agent.ensure_subprocess_alive: respawned PtyServer for " <>
                    URI.to_string(agent_uri)
                )

                :ok

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

        case reprovision_source_credential(config_home, source_path, reprovision_opts()) do
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

  # Provisioner opts (OAuth `http_post` + `now_ms` clock) for the respawn-time
  # re-provision. PRODUCTION → `[]` (the provisioner uses real `:httpc` + the
  # system clock). TESTS inject a stubbed `http_post`/`now_ms` via the established
  # `:ezagent_plugin_cc` app-env seam (same pattern as `:mcp_config_dir`, `:ws_url`)
  # so the PATH-LEVEL respawn test can drive an
  # EXPIRED→refreshed source through `ensure_subprocess_alive/2` WITHOUT hitting the
  # network or rotating a real token. No data shim — the injection never rides in
  # `respawn_template_data`.
  defp reprovision_opts do
    case Application.get_env(:ezagent_plugin_cc, :source_reprovision_opts) do
      opts when is_list(opts) -> opts
      _ -> []
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
  defp ensure_pty_server(agent_uri, cwd, tmpl, resume?) do
    require_transport_join(agent_uri)

    # §5.B follow-up (b) — DURABLE first-run-dialog suppression. claude shows its
    # theme / "Select login method" dialogs on first run against an un-onboarded
    # config home EVEN with a valid materialized `.credentials.json`; a headless
    # PTY can't answer them and the bridge never binds. Mark onboarding complete in
    # the resolved per-agent config home BEFORE launch so the first-run flow never
    # starts. Runs on BOTH the fresh-spawn AND respawn paths (this is the single
    # chokepoint both reach) so the marker survives the agent's own restarts. The
    # PtyServer `:theme_dialog` / `:login_method_dialog` auto-prompts remain the
    # fallback; best-effort (never tears the agent down — see try_ensure/2).
    config_home = resolve_config_home(agent_uri, tmpl)

    _ =
      Ezagent.PluginCc.Template.OnboardingBootstrap.try_ensure(config_home, agent_uri,
        project_cwd: cwd
      )

    with {:ok, params} <-
           Ezagent.PluginCc.Template.SpawnPlan.build_pty_params(
             agent_uri,
             cwd,
             tmpl,
             @compile_env
           ),
         params = maybe_resume_conversation(params, resume?, agent_uri),
         {:ok, _pid} <- start_pty(agent_uri, params) do
      :ok
    end
  end

  # cc-PTY hardening 2026-07-10 (audit #2). On the respawn path, inject
  # `--continue` into the built argv so the restarted `claude` resumes THIS
  # agent's conversation. Fresh spawns (resume? == false) and `:test`-env params
  # (no `:cmd_override`) are returned unchanged.
  defp maybe_resume_conversation(params, true, agent_uri) do
    case Ezagent.PluginCc.Template.SpawnPlan.inject_resume_flag(params) do
      ^params ->
        params

      updated ->
        Logger.info(
          "cc.agent: respawn resumes the prior conversation via " <>
            "#{Ezagent.PluginCc.Template.SpawnPlan.resume_flag()} for " <>
            URI.to_string(agent_uri)
        )

        updated
    end
  end

  defp maybe_resume_conversation(params, _resume?, _agent_uri), do: params

  defp require_transport_join(%URI{} = agent_uri) do
    unless @compile_env == :test do
      :ok =
        Ezagent.Agent.TransportReadiness.require_transport_join(agent_uri,
          timeout_ms: transport_join_timeout_ms()
        )
    end

    :ok
  end

  @doc """
  Transport-join gate timeout in ms. Defaults to
  #{@default_transport_join_timeout_ms}ms; override with
  `config :ezagent_plugin_cc, :transport_join_timeout_ms`.
  """
  @spec transport_join_timeout_ms() :: pos_integer()
  def transport_join_timeout_ms do
    Application.get_env(
      :ezagent_plugin_cc,
      :transport_join_timeout_ms,
      @default_transport_join_timeout_ms
    )
  end

  defp start_pty(agent_uri, params) do
    case Ezagent.Domain.Pty.start(agent_uri, params) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Idempotent adopt (start-path race). Stays idempotent, but is no longer
        # SILENT: this clause is what masked chain B's premature PTY (#1096).
        Logger.warning(
          "cc.agent: PtyServer already running for #{URI.to_string(agent_uri)} " <>
            "(pid=#{inspect(pid)}) — adopting. On a fresh create this means " <>
            "something launched the PTY early."
        )

        :telemetry.execute([:ezagent, :cc, :pty, :already_started], %{count: 1}, %{
          agent_uri: agent_uri
        })

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
end

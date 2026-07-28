defmodule Ezagent.Entity.Agent.TemplateSpawn.SandboxState do
  @moduledoc false

  # PR3 2026-05-24 — the `:sandbox` slice state the chokepoint records on
  # each fresh worker after ownership obligations (config_dir +
  # template_class + respawn data). Relocated from `TemplateSpawn`
  # (#201 PR-3 — oversized-module fitness).

  # PR3 2026-05-24 — dispatch `sandbox.update_config` on each worker URI
  # so the agent's `:sandbox` slice carries the per-agent
  # `config_dir_path` + `template_class`. Both fields are needed by
  # `Sandbox.invoke(:destroy, ...)` to invoke the right cleanup callback
  # with the right path.
  #
  # Codex PR3 round-2 HIGH-1 — SKIP dispatch entirely when meta lacks
  # `:config_dir_path`. The :already_started loser path returns no
  # config_dir_path; if we still dispatched, we'd write `nil` into the
  # slice and CLOBBER the live state the :started winner just populated.
  # The result would be a slice with no path → destroy_config_dir would
  # never run → credential dir leaks.
  #
  # When meta carries :config_dir_path = nil EXPLICITLY (a plugin that
  # opted out of per-agent dirs, e.g. echo template returning
  # %{config_dir_path: nil}), we DO dispatch — recording that the
  # template_class manages no dir is a meaningful state. The "missing
  # key" vs "explicit nil" distinction is the gate.
  @doc false
  def record_sandbox_state(workers, meta, template_class) do
    if Map.has_key?(meta, :config_dir_path) do
      do_record_sandbox_state(
        workers,
        Map.get(meta, :config_dir_path),
        template_class,
        # PTY-orphan-restart 2026-05-26 — the plugin Template Class
        # may also emit `:respawn_template_data` in meta (cc does;
        # echo doesn't). Passed through to `sandbox.update_config` so
        # the slice carries enough state for `Sandbox.post_init/2` to
        # respawn the subprocess on a phx restart. Absent in meta →
        # `nil` here → not written into the slice.
        Map.get(meta, :respawn_template_data)
      )
    else
      # Loser/short-circuit path: meta has no :config_dir_path → don't
      # touch the slice (it was populated by the winner OR was already
      # in the right state). No-op = safe.
      :ok
    end
  end

  defp do_record_sandbox_state(workers, config_dir, template_class, respawn_data) do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      target = Ezagent.URI.new!("#{URI.to_string(worker_uri)}?action=sandbox.update_config")

      if sandbox_state_matches?(worker_uri, config_dir, template_class, respawn_data) do
        {:cont, :ok}
      else
        # codex E2E fix v2 Bug A (2026-05-29) — the Agent Kind was just
        # spawned by `template_class.instantiate/3`. `Kind.Server.init/1`
        # registers `:not_ready` synchronously and returns
        # `{:continue, :announce_ready}`; the `:ready` flip happens
        # asynchronously in `handle_continue` after the post-init Behavior
        # chain runs. The orchestrator-spawn path
        # (`Session.ensure_orchestrator` → `spawn_from_template_content` →
        # `record_sandbox_state`) hits this dispatch microseconds after
        # `start_link` returns — typically before the GenServer's
        # `handle_continue(:announce_ready, ...)` message has been
        # processed. A `:call` dispatch in that window fails fast with
        # `{:error, :not_ready}` (hard invariant #3, so the synchronous
        # caller doesn't block on `deadline_ms`), and the Sandbox slice's
        # `respawn_template_data` never gets written — which means
        # `Sandbox.post_init/2` cannot re-spawn the PTY subprocess on the
        # next phx restart. Allen e2e symptom 2026-05-28 was
        # `{:sandbox_update_config_failed, %URI{cc_orchestrator-main},
        # :not_ready}`.
        #
        # Bridge-backed cc agents are spawned with this sandbox state in their
        # Kind init args before transport readiness can hold ReadyGate at
        # `:not_ready`. The slice-match check above covers that case without
        # adding a core dispatch bypass; this fallback remains the normal
        # post-spawn write path for templates that do not initialize sandbox in
        # spawn args.
        #
        # FIRE-AND-FORGET (go-live 2026-07-06): do NOT block the spawning
        # caller on the agent reaching `:ready`. This shared spawn machinery
        # was tuned for the SYNCHRONOUS cc-orchestrator spawn (the 5s
        # `ReadyGate.await` above), but the socialware-install path reuses it
        # for role-slot agents of ANY flavor. A cold agent whose `activate`
        # provisions a heavy subprocess — e.g. the `np` recipe's first
        # `uv run` per container downloading numpy/sympy, measured ~9.6s —
        # would hold the await past the `create_session` dispatch budget
        # (`deadline_ms || 5000`), the observed "first socialware install per
        # boot times out at 5s" (install completed server-side regardless).
        #
        # Switch to `:cast`: a cast to a not-ready target is BUFFERED via
        # `PendingDelivery` (`invocation.ex` `{:not_ready, :cast}`) and
        # delivered once the agent flips `:ready`; a ready target gets it
        # immediately. Either way the spawning caller returns without
        # blocking — so we drop the `ReadyGate.await`. The `:sandbox` slice
        # write only feeds respawn-on-restart (`Sandbox.post_init/2`), which
        # ALSO self-heals via `ensure_subprocess_alive`/CascadeRuntime, so a
        # late (or, on a dead agent, dropped) write never corrupts a running
        # agent — hence no rollback-on-write-failure anymore.
        #
        # Self-authority (#154): `caller: worker_uri` dispatching to
        # `worker_uri?action=sandbox.update_config` IS the agent acting on
        # its OWN `:sandbox` slice (capbac.md §7 actor-self). The agent's own
        # `sandbox.update_config` cap is carried INLINE in `ctx.caps` (the
        # step-5.5 `granted_via_ctx_caps?` authorizer), scoped to this
        # specific agent; `granted_by` = the agent itself, never persisted
        # through `Ezagent.Identity.Grant`.
        admin = Ezagent.Entity.User.admin_uri()

        case Ezagent.Cap.issue_for_action({:admin, admin}, worker_uri, target) do
          {:ok, cap} ->
            _ =
              Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                target: target,
                mode: :cast,
                args: %{
                  config_dir_path: config_dir,
                  template_class: template_class,
                  respawn_template_data: respawn_data
                },
                ctx: %{
                  caller: worker_uri,
                  authenticated_principal: worker_uri,
                  caps: [cap],
                  # `:ignore` — nobody awaits this write. `Kind.Server.handle_cast`
                  # unconditionally calls `Invocation.reply(inv.ctx, ...)`, which
                  # requires a `:reply` key (an absent key raises FunctionClause);
                  # `:ignore` is the no-op reply target for fire-and-forget.
                  reply: :ignore
                },
                origin: :trusted_internal
              })

            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:sandbox_update_config_cap_issue_failed, worker_uri, reason}}}
        end
      end
    end)
  end

  defp sandbox_state_matches?(%URI{} = worker_uri, config_dir, template_class, respawn_data) do
    case Ezagent.Kind.read(worker_uri, :sandbox, spawn: :never) do
      {:ok, state} when is_map(state) ->
        Map.get(state, :config_dir_path) == config_dir and
          Map.get(state, :template_class) == template_class and
          Map.get(state, :respawn_template_data) == respawn_data

      _ ->
        false
    end
  end
end

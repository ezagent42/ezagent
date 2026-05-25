defmodule Ezagent.Orchestrator.Tools do
  @moduledoc """
  Orchestrator MCP tool surface — the 7 tools the cc-orchestrator
  (Decision #136, SPEC §7-3) exposes to the LLM it hosts.

  ## The 7 tools

  | Tool | Args | Effect |
  |---|---|---|
  | `add_agent_slot` | slot_name, agent_template_uri, optional prompt_override | Ensures a worker agent is alive at `slot_name` from the given template (reconciler — idempotent) |
  | `remove_agent_slot` | slot_name | Ensures the worker for `slot_name` is absent (reconciler — idempotent) |
  | `update_agent_template` | slot_name, new_agent_template_uri | Converges the slot to the requested template (reconciler — idempotent) |
  | `write_matcher` | matcher_ast, receiver_slot_names | Inserts routing rule into the live RuleStore |
  | `update_template` | (no args) | Snapshot current session state → new version of current parent SessionTemplate |
  | `save_template_as` | new_name | Snapshot current session state → first version of NEW SessionTemplate |
  | `list_templates` | optional name_filter | Returns visible AgentTemplate + SessionTemplate URIs (CapBAC-filtered) |

  ## Generator-as-reconciler — PR-C

  PR-C (SPEC `docs/superpowers/specs/2026-05-23-generator-reconciler.md` §4)
  rewrites the 3 agent-slot tools as reconcilers (converge-to-spec)
  rather than two-phase rollback-safe sagas. Each tool's contract:

  > "ensure the slot is in the desired state."

  - **already-converged → no-op, return current state**;
  - **drift → forward-progress one pass**;
  - **partial-converged → `{:partial, _}`** with per-step diagnostics — a
    re-invocation completes the rest.

  The pre-PR-C `:update_aborted` + `:update_needs_manual_repair`
  saga-recovery error shapes are **deleted**. The reconciler treats a
  failed step as expected intermediate state; the next invocation
  re-evaluates from current reality and completes whatever is still
  pending. There is no rollback machinery to fail.

  ## PR-5 carry-overs (still in force)

  - **No `admin_caps` anywhere in the tool path.** Every dispatch `ctx`
    carries `caps: <the orchestrator's 4 delegated caps>` and `caller:
    <the orchestrator's URI>`. A missing delegated cap returns
    `{:error, :unauthorized}` — fail closed, never a fallback to
    ambient authority.
  - **CapBAC is enforced AT EVERY DISPATCH** — the reconciler model
    does not relax authority gates; it just retries on completable
    failures.
  - **Workspace isolation (rounds 1-3)** + **fresh? gating (rounds 6-8)**
    + **atomic-routing-repoint Repo.transaction (round 4)** + **Lifecycle
    terminate (round 5/6)** — all preserved.

  ## Calling convention

  Every tool takes a trailing `opts` keyword list carrying the
  orchestrator's caller context:

      Tools.add_agent_slot("backend-dev",
        URI.parse("template://agent/system/cc-backend"),
        nil,
        caller: %URI{} = orchestrator_uri,
        caps: caps,
        session_uri: %URI{} = sess,
        workspace_uri: %URI{} = ws)

  Required keys per tool documented at each `@doc`. The orchestrator MCP
  server fills these in from its bound per-orchestrator context before
  invoking — the LLM never supplies caller / caps / session context.

  ## Design locks (CI-gated, see tools_test.exs + reconciler invariant test)

  - Exactly 7 tools (locks against authority creep).
  - No `:fork` tool (Decision #141 — fork is a SessionTemplate
    registry verb, not an in-session orchestrator verb).
  - No `:grant_cap` tool (Decision #137 — cap delegation only
    happens at Generator boot, never mid-session).
  - **PR-C invariant**: NO saga-rollback helpers (`compensate_orphan_worker`,
    `abort_swap_after_repoint_rollback`, `halt_routing_revert_failed`,
    `manual_repair_error`, `rollback_slot_to_old`,
    `revert_receivers_by_ids_txn`) — see
    `apps/ezagent_domain_chat/test/integration/reconciler_test.exs`
    "V1-R7" describe block.

  ## Working-copy derivation (Phase 7 completion PR-2 — SPEC §1.3 / §1.6)

  The `template_working_copy` field on the Session's `:chat` slice
  (`Ezagent.Behavior.Chat`) IS the durable source-template record. The
  agent-slot tools maintain `template_working_copy.agent_slots` via the
  `chat.set_working_copy` dispatch.
  """

  require Logger

  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.Invocation

  @doc "The 7 orchestration tool names. CI gate test pins this list at 7."
  @spec tool_names() :: [atom()]
  def tool_names do
    [
      :add_agent_slot,
      :remove_agent_slot,
      :update_agent_template,
      :write_matcher,
      :update_template,
      :save_template_as,
      :list_templates
    ]
  end

  @doc "True iff `name` is one of the 7 declared orchestration tools."
  @spec tool?(atom()) :: boolean()
  def tool?(name) when is_atom(name), do: name in tool_names()
  def tool?(_), do: false

  # === add_agent_slot ====================================================

  @doc """
  Reconciler — ensure a worker agent is alive at `slot_name` from
  `agent_template_uri`. SPEC §2 step 3 applied to a single slot.

  Idempotent:

  - **Slot already converged** (slot recorded with this template URI,
    live worker URI owned by us in the lineage + workspace registries)
    → no-op, returns `{:ok, worker_uri}`.
  - **Slot recorded at a DIFFERENT template URI** → returns
    `{:error, :slot_conflict}`. Operator must invoke `update_agent_template`
    explicitly — a same-slot template change is a SEPARATE intent
    captured by that tool's no-op-or-converge semantics.
  - **Slot absent, no live worker** → spawn fresh via the `template.instantiate`
    dispatch (round-6+ `fresh?` gating still applies), record the slot
    tuple in the working copy.

  The CapBAC + workspace-isolation gates (rounds 1-3) and the round-7
  ownership predicate (a non-fresh adoption is refused) are preserved.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, worker_uri}` or `{:error, reason}`.

  `prompt_override` is accepted for API parity with the SPEC but is not
  consumed — the worker's prompt comes from its AgentTemplate's
  `claude_config_dir/settings.json` (Decision #136).
  """
  @spec add_agent_slot(String.t(), URI.t(), String.t() | nil, keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def add_agent_slot(slot_name, %URI{} = agent_template_uri, prompt_override \\ nil, opts \\ [])
      when is_binary(slot_name) do
    _ = prompt_override

    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      reconcile_add_slot(
        slot_name,
        agent_template_uri,
        session_uri,
        workspace_uri,
        caller,
        caps
      )
    end
  end

  # add_agent_slot under the reconciler model.
  #
  # The slot's desired state is "(slot_name, agent_template_uri,
  # generation=0)" with a live worker URI owned by us.
  #
  # No-op detect: the slot already exists at this template URI AND its
  # recorded worker URI is alive AND lineaged under our orchestrator AND
  # workspace-bound to our workspace → done. Reconciler convention: no
  # generation bump, no `template.instantiate` dispatch, no slot rewrite.
  #
  # Conflict detect: the slot exists at a DIFFERENT template URI →
  # surface `:slot_conflict`. A SAME-SLOT template change is the
  # `update_agent_template` reconciler's job — keeping the two tools'
  # semantics distinct keeps the orchestrator's intent legible.
  #
  # Otherwise: spawn the worker fresh via `template.instantiate` (the
  # round-6 `fresh?` signal is required to be `true` — adopting a
  # foreign / orphan worker is refused). Record the slot tuple.
  defp reconcile_add_slot(
         slot_name,
         %URI{} = agent_template_uri,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps
       ) do
    case find_slot_tuple(session_uri, slot_name) do
      {_n, %URI{} = current_src, %URI{} = current_worker, _gen} ->
        cond do
          URI.to_string(current_src) == URI.to_string(agent_template_uri) and
              worker_owned_by_us?(current_worker, caller, workspace_uri) ->
            {:ok, current_worker}

          URI.to_string(current_src) == URI.to_string(agent_template_uri) ->
            # Same template, but the worker is missing / owned by
            # someone else. Re-establish the worker.
            spawn_and_record_slot(
              slot_name,
              agent_template_uri,
              session_uri,
              workspace_uri,
              caller,
              caps,
              0
            )

          true ->
            {:error, :slot_conflict}
        end

      {_n, _current_src, nil, _gen} ->
        # Slot exists in working copy but has no live worker URI
        # recorded (legacy 2-tuple / failed earlier converge). Honor
        # the requested template — re-establish from scratch at gen 0.
        spawn_and_record_slot(
          slot_name,
          agent_template_uri,
          session_uri,
          workspace_uri,
          caller,
          caps,
          0
        )

      nil ->
        spawn_and_record_slot(
          slot_name,
          agent_template_uri,
          session_uri,
          workspace_uri,
          caller,
          caps,
          0
        )
    end
  end

  defp spawn_and_record_slot(
         slot_name,
         %URI{} = agent_template_uri,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps,
         generation
       ) do
    instance_name =
      Ezagent.Entity.Agent.session_instance_name(
        slot_name,
        session_discriminator(session_uri),
        generation
      )

    with {:ok, worker_uri} <-
           instantiate_worker(agent_template_uri, instance_name, workspace_uri, caller, caps),
         :ok <-
           upsert_agent_slot(
             session_uri,
             slot_name,
             agent_template_uri,
             worker_uri,
             generation,
             caller,
             caps
           ) do
      {:ok, worker_uri}
    end
  end

  # Dispatch `template.instantiate` on the AgentTemplate Kind. The
  # action runs in-process with the slice in hand, resolves the flavor
  # Class, and spawns the worker — recording lineage under `caller`.
  # `instance_name` is the SESSION-UNIQUE live instance name (CRITICAL
  # fix) — the caller built it via `Agent.session_instance_name/3`.
  #
  # codex round-7 HIGH-1 — the spawn path WANTS a worker it freshly
  # created. Lineage + workspace binding only happen for `fresh?: true`
  # workers. A `fresh?: false` result means the instantiate adopted a
  # pre-existing worker — that worker has NOT been re-parented or bound,
  # and the slot tool must not silently adopt it (it would record a slot
  # pointing at a foreign worker with no lineage). Treat `fresh?: false`
  # as a clear error condition.
  defp instantiate_worker(
         %URI{} = agent_template_uri,
         instance_name,
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps
       )
       when is_binary(instance_name) do
    case instantiate_worker_detailed(
           agent_template_uri,
           instance_name,
           workspace_uri,
           caller,
           caps
         ) do
      {:ok, %{worker_uri: worker_uri, fresh?: true}} -> {:ok, worker_uri}
      {:ok, %{fresh?: false}} -> {:error, :candidate_uri_already_live}
      {:error, _} = err -> err
    end
  end

  # The detailed instantiate, returning the `fresh?` signal
  # `Ezagent.Entity.Agent.spawn_from_template_content/4` reconstructs
  # (did THIS call create the worker, or adopt a pre-existing one).
  # `update_agent_template`'s swap path uses it to refuse silently
  # adopting an already-live worker.
  defp instantiate_worker_detailed(
         %URI{} = agent_template_uri,
         instance_name,
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps
       )
       when is_binary(instance_name) do
    with {:ok, _pid} <- ensure_template_alive(agent_template_uri) do
      target = URI.parse("#{URI.to_string(agent_template_uri)}?action=template.instantiate")

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{
               instance_name: instance_name,
               workspace_uri: workspace_uri,
               spawned_by: caller
             },
             ctx: ctx(caller, caps)
           }) do
        {:ok, %{workers: [worker_uri | _]} = result} ->
          # `fresh?` absent (a plugin / test path that predates the
          # round-5 signal) is conservatively treated as NOT fresh — the
          # swap then errs on the side of refusing a possible adoption.
          {:ok, %{worker_uri: worker_uri, fresh?: Map.get(result, :fresh?, false)}}

        {:ok, %{workers: []}} ->
          {:error, :instantiate_returned_no_worker}

        {:error, _} = err ->
          err

        other ->
          {:error, {:unexpected_instantiate_result, other}}
      end
    end
  end

  # The reconciler's "is this worker owned by us" predicate — the same
  # contract `Ezagent.Entity.Session.worker_already_owned_by_us?/3`
  # exposes for slot fast-paths (PR-A § 5). A worker is "owned by us"
  # iff its `AgentLineage` row points at our orchestrator AND its
  # `WorkspaceRegistry` binding points at our workspace.
  defp worker_owned_by_us?(%URI{} = worker_uri, %URI{} = orch_uri, %URI{} = ws_uri) do
    Ezagent.Entity.Session.worker_already_owned_by_us?(worker_uri, orch_uri, ws_uri)
  end

  # The session-scoped discriminator folded into every LIVE worker
  # instance name — the session URI's name segment (kept in sync with
  # `Ezagent.Entity.Session.session_discriminator/1`).
  defp session_discriminator(%URI{} = session_uri) do
    case session_uri.path do
      "/" <> rest ->
        case String.split(rest, "/", parts: 2) do
          [_ws, name] when name != "" -> name
          _ -> session_uri.host || "session"
        end

      _ ->
        session_uri.host || "session"
    end
  end

  # === remove_agent_slot =================================================

  @doc """
  Reconciler — ensure the worker for `slot_name` is absent. SPEC §2 step
  3 applied to a single slot in the "delete" direction.

  Idempotent:

  - **Slot already absent** → `{:ok, :already_removed}`. No dispatch.
  - **Slot present** → remove from working copy + remove routing rules
    naming the worker (transactional via the round-4 `Repo.transaction`
    primitive) + terminate the worker via `Behavior.Lifecycle` `:terminate`
    (round-5/6). A re-run after a partial failure picks up at whichever
    step did not converge.

  CapBAC: `lifecycle.terminate` is gated by cap #2
  (`{:spawned_by, orchestrator}`) — the orchestrator may terminate only
  workers it itself spawned.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, :removed}` or `{:ok, :already_removed}` on success;
  `{:partial, info}` if some converging step did not complete (e.g.
  routing-rule removal failed); `{:error, reason}` otherwise.
  """
  @spec remove_agent_slot(String.t(), keyword()) ::
          {:ok, :removed | :already_removed}
          | {:partial, map()}
          | {:error, term()}
  def remove_agent_slot(slot_name, opts \\ []) when is_binary(slot_name) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      reconcile_remove_slot(slot_name, session_uri, workspace_uri, caller, caps)
    end
  end

  defp reconcile_remove_slot(
         slot_name,
         %URI{} = session_uri,
         %URI{} = _workspace_uri,
         %URI{} = caller,
         caps
       ) do
    case find_slot_tuple(session_uri, slot_name) do
      nil ->
        # Idempotent — nothing recorded, nothing to do.
        {:ok, :already_removed}

      {_n, _src, nil, _gen} ->
        # Slot recorded but with no live worker URI (legacy / partial).
        # Just drop the slot tuple; nothing to terminate.
        case drop_agent_slot(session_uri, slot_name, caller, caps) do
          :ok -> {:ok, :removed}
          {:error, reason} -> {:error, reason}
        end

      {_n, _src, %URI{} = worker_uri, _gen} ->
        do_remove_slot(slot_name, worker_uri, session_uri, caller, caps)
    end
  end

  defp do_remove_slot(
         slot_name,
         %URI{} = worker_uri,
         %URI{} = session_uri,
         %URI{} = caller,
         caps
       ) do
    # Step 1 — terminate the worker via `lifecycle.terminate` (round 5/6
    # Behavior dispatch — cap #2 `{:spawned_by, orchestrator}` is
    # checked here). A CapBAC denial here is the security gate: bail
    # IMMEDIATELY with `{:error, :unauthorized}` so the orchestrator
    # B cannot use remove_agent_slot to mutate the working copy of a
    # slot belonging to orchestrator A's worker.
    #
    # `terminate_worker/3` already treats `:no_such_actor` / `:not_ready`
    # as idempotent success — a half-terminated slot's worker shows up
    # gone, which is what we want.
    case terminate_worker(worker_uri, caller, caps) do
      :ok ->
        do_remove_slot_after_terminate(slot_name, worker_uri, session_uri, caller, caps)

      {:error, :unauthorized} = err ->
        err

      {:error, reason} ->
        # A non-authorization failure (e.g. dispatch error, undefined
        # Behavior) is a real terminate-step failure. Surface as
        # `:partial` so a re-invocation can complete the removal once
        # the worker is reachable.
        {:partial,
         %{
           slot: slot_name,
           worker_uri: worker_uri,
           pending: [:worker],
           errors: [{:worker, reason}]
         }}
    end
  end

  defp do_remove_slot_after_terminate(
         slot_name,
         %URI{} = worker_uri,
         %URI{} = session_uri,
         %URI{} = caller,
         caps
       ) do
    pending = []
    errors = []

    # Step 2 — remove routing rules naming the worker, transactionally
    # (round-4 atomic-repoint primitive REUSED for prune).
    {pending, errors} =
      case prune_routing_rules_for(worker_uri) do
        :ok ->
          {pending, errors}

        {:error, reason} ->
          {[:routing | pending], [{:routing, reason} | errors]}
      end

    # Step 3 — drop the slot tuple from the working copy.
    {pending, errors} =
      case drop_agent_slot(session_uri, slot_name, caller, caps) do
        :ok -> {pending, errors}
        {:error, reason} -> {[:working_copy | pending], [{:working_copy, reason} | errors]}
      end

    case {pending, errors} do
      {[], []} ->
        {:ok, :removed}

      _ ->
        {:partial,
         %{
           slot: slot_name,
           worker_uri: worker_uri,
           pending: Enum.reverse(pending),
           errors: Enum.reverse(errors)
         }}
    end
  end

  # PR3 2026-05-24 (Allen) — dispatches `sandbox.destroy` (migrated from
  # `lifecycle.terminate` per PR2 #288 round-4 HIGH-1). `sandbox.destroy`
  # is a drop-in superset: it BOTH runs the plugin Template Class's
  # `destroy_config_dir/2` FS cleanup AND schedules Kind-process
  # termination (same detached-Task pattern as `lifecycle.terminate`).
  # For agents with no `:sandbox` slice or no template_class (echo,
  # curl, np that never populated), Sandbox short-circuits the cleanup
  # and just schedules termination — safe drop-in for all flavors.
  defp terminate_worker(%URI{} = worker_uri, %URI{} = caller, caps) do
    target = URI.parse("#{URI.to_string(worker_uri)}?action=sandbox.destroy")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: ctx(caller, caps)
         }) do
      # PR3 round-1 HIGH-3 (codex) — propagate cleanup failures to
      # the orchestrator caller. Process IS gone (sandbox.destroy
      # schedules termination unconditionally), but the FS dir may
      # still be on disk holding credentials. Surface as
      # `{:error, {:terminated_with_cleanup_failure, reason}}` so the
      # caller knows there's residue to investigate. (Sandbox slice
      # is also preserved per round-4 HIGH-2 for ops retry.)
      {:ok, %{destroyed: true, cleanup: :ok}} ->
        :ok

      {:ok, %{destroyed: true, cleanup: {:error, reason}}} ->
        {:error, {:terminated_with_cleanup_failure, reason}}

      # Defensive fallback if cleanup key is absent (e.g. a Sandbox
      # version older than PR3 round-4 — treat as success).
      {:ok, %{destroyed: true}} ->
        :ok

      # Legacy lifecycle.terminate shape — kept for safety during
      # in-flight migrations; harmless after Sandbox lands.
      {:ok, {:ok, :terminated}} -> :ok
      {:ok, :terminated} -> :ok
      # The worker Kind is not alive — dispatch to an absent / not-ready
      # actor; idempotent termination treats this as already-gone.
      {:error, :no_such_actor} -> :ok
      {:error, :not_ready} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_terminate_result, other}}
    end
  end

  # === update_agent_template =============================================

  @doc """
  Reconciler — converge `slot_name` to `new_agent_template_uri`
  (SPEC `docs/superpowers/specs/2026-05-23-generator-reconciler.md` §4).

  The slot's desired state is "(slot_name, new_agent_template_uri,
  generation+1, fresh worker URI under the bumped generation)" — UNLESS
  the slot is already at the requested template URI AND the worker is
  alive + owned + routing-pointed-at-it, in which case the desired
  state IS the current state (no-op).

  No-op detect runs BEFORE any generation bump (SPEC §4.1 codex rev-2
  HIGH-4). A slot at generation N at the requested template URI with a
  healthy worker returns `{:ok, current_worker_uri}` with the SAME pid
  + the SAME generation across re-invocations.

  Otherwise, the convergence routine (SPEC §4.2):

  1. **spawn the new worker** at the bumped-generation URI — round-6
     `fresh?` gating refuses adopting a pre-existing worker;
  2. **repoint routing rules** from the old worker URI to the new one
     atomically inside `EzagentCore.Repo.transaction/1` (round-4
     primitive — KEPT);
  3. **commit the slot tuple** to the new (template_uri, worker_uri,
     generation+1) via the `chat.set_working_copy` dispatch;
  4. **terminate the OLD worker** via `Behavior.Lifecycle` `:terminate`
     — only after routing AND slot both name the new worker.

  Steps 2-4 each leave the system in a forward-progress state; a
  failure mid-way leaves the new worker alive + the routing or slot
  partially converged + the OLD worker alive. A re-invocation
  re-evaluates from current reality and completes whichever step did
  not converge. There is no rollback.

  ## Return shape (SPEC §1.2 + §6 PR-C)

  - `{:ok, new_worker_uri}` — fully converged this pass;
  - `{:ok, current_worker_uri}` — already at target (no-op path,
    `current_worker_uri` is the OLD worker URI);
  - `{:partial, info}` — at least one step did not converge; `info`
    carries `:slot`, `:new_worker_uri` (if spawned), `:pending`
    (list of unfinished steps), `:errors` (per-step reason).
    A re-invocation continues forward progress.
  - `{:error, reason}` — preflight / authorization failure; nothing
    mutated.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.
  """
  @spec update_agent_template(String.t(), URI.t(), keyword()) ::
          {:ok, URI.t()} | {:partial, map()} | {:error, term()}
  def update_agent_template(slot_name, %URI{} = new_agent_template_uri, opts \\ [])
      when is_binary(slot_name) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      reconcile_update_agent_template(
        slot_name,
        new_agent_template_uri,
        session_uri,
        workspace_uri,
        caller,
        caps
      )
    end
  end

  defp reconcile_update_agent_template(
         slot_name,
         %URI{} = new_agent_template_uri,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps
       ) do
    case find_slot_tuple(session_uri, slot_name) do
      nil ->
        {:error, :no_such_slot}

      {_n, _src, nil, _gen} ->
        {:error, :no_live_worker}

      {_n, %URI{} = current_src, %URI{} = current_worker, current_gen} = current_slot ->
        if slot_already_at_target?(
             current_slot,
             new_agent_template_uri,
             workspace_uri,
             caller
           ) do
          {:ok, current_worker}
        else
          converge_slot_to(
            slot_name,
            new_agent_template_uri,
            current_src,
            current_worker,
            current_gen,
            session_uri,
            workspace_uri,
            caller,
            caps
          )
        end
    end
  end

  # SPEC §4.1 — no-op detect BEFORE any generation bump (codex rev-2
  # HIGH-4). All FIVE facts must agree for "already at target":
  #
  #   1. slot's template URI == requested template URI
  #   2. recorded worker URI is alive in KindRegistry
  #   3. worker is lineaged under our orchestrator (caller)
  #   4. worker is workspace-bound to our workspace
  #   5. routing rules name the recorded worker (no stale routes
  #      pointing at a defunct previous worker)
  #
  # Folded into a single predicate the reconciler can short-circuit on.
  defp slot_already_at_target?(
         {_n, %URI{} = current_src, %URI{} = current_worker, _gen},
         %URI{} = new_template_uri,
         %URI{} = workspace_uri,
         %URI{} = caller
       ) do
    same_template? =
      URI.to_string(current_src) == URI.to_string(new_template_uri)

    same_template? and
      worker_owned_by_us?(current_worker, caller, workspace_uri) and
      routing_targets_worker?(current_worker, workspace_uri)
  end

  defp slot_already_at_target?(_other, _new, _ws, _caller), do: false

  # True iff every routing rule that names `worker_uri` is enabled AND
  # in the right workspace AND not also naming a stale URI for the same
  # logical receiver. Conservative: a workspace with no routing rule
  # naming the worker satisfies the predicate vacuously (a slot may
  # legitimately have no inbound routing). We're testing for the
  # ABSENCE of stale rules pointing at a different worker for the same
  # slot — i.e., that nothing diverges from the current worker.
  defp routing_targets_worker?(%URI{} = worker_uri, %URI{} = workspace_uri) do
    table = EzagentDomainChat.Routing.MentionRouting
    worker_str = URI.to_string(worker_uri)
    ws_str = URI.to_string(workspace_uri)

    rules =
      try do
        Ezagent.Routing.RuleStore.list(table)
      rescue
        _ -> []
      end

    # The slot is "routing-converged" iff no enabled rule in this
    # workspace names a receiver URI that LOOKS like the same slot but
    # at a different generation. In v1 we just check: every rule that
    # names this worker is enabled. Rules naming OTHER workers are
    # someone else's concern.
    rules
    |> Enum.filter(fn r -> r.workspace_uri == ws_str end)
    |> Enum.filter(fn r -> worker_str in (r.receivers || []) end)
    |> Enum.all?(fn r -> r.enabled end)
  end

  # SPEC §4.2 — the convergence routine when drift exists.
  defp converge_slot_to(
         slot_name,
         %URI{} = new_template_uri,
         %URI{} = old_template_uri,
         %URI{} = old_worker_uri,
         old_generation,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps
       ) do
    new_generation = old_generation + 1
    discriminator = session_discriminator(session_uri)

    instance_name =
      Ezagent.Entity.Agent.session_instance_name(slot_name, discriminator, new_generation)

    # Preflights — slot-name uniqueness across the session at the
    # bumped generation + template read-cap check + candidate-URI
    # freshness (MEDIUM-3 round 4 — close the TOCTOU window). On
    # preflight failure: nothing has mutated; surface as `:error`.
    preflight_result =
      with :ok <-
             preflight_swap_uniqueness(session_uri, slot_name, new_generation, discriminator),
           {:ok, new_template_content} <-
             preflight_template_read(new_template_uri, caller, caps),
           :ok <-
             preflight_candidate_uri_free(
               new_template_content,
               instance_name,
               workspace_uri,
               old_worker_uri
             ) do
        :ok
      end

    case preflight_result do
      :ok ->
        do_converge_slot(
          slot_name,
          new_template_uri,
          old_template_uri,
          old_worker_uri,
          new_generation,
          instance_name,
          session_uri,
          workspace_uri,
          caller,
          caps
        )

      {:error, _} = err ->
        err
    end
  end

  defp do_converge_slot(
         slot_name,
         %URI{} = new_template_uri,
         %URI{} = old_template_uri,
         %URI{} = old_worker_uri,
         new_generation,
         instance_name,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps
       ) do
    _ = old_template_uri

    # Step 1 — spawn the new worker. The round-6 `fresh?` gate
    # (`require_fresh_candidate`) refuses adopting a worker registered
    # in the TOCTOU window — derived from the ATOMIC spawn result.
    case require_fresh_candidate(
           instantiate_worker_detailed(
             new_template_uri,
             instance_name,
             workspace_uri,
             caller,
             caps
           )
         ) do
      {:ok, %{worker_uri: new_worker_uri}} ->
        do_converge_slot_after_spawn(
          slot_name,
          new_template_uri,
          old_worker_uri,
          new_worker_uri,
          new_generation,
          session_uri,
          caller,
          caps
        )

      {:error, reason} ->
        # Step-1 failure: nothing committed; nothing to terminate (the
        # `require_fresh_candidate` arm rejects a pre-existing live URI
        # without spawning, and an instantiate error left the candidate
        # absent). The next pass re-evaluates.
        {:error, reason}
    end
  end

  defp do_converge_slot_after_spawn(
         slot_name,
         %URI{} = new_template_uri,
         %URI{} = old_worker_uri,
         %URI{} = new_worker_uri,
         new_generation,
         %URI{} = session_uri,
         %URI{} = caller,
         caps
       ) do
    pending = []
    errors = []

    # Step 2 — atomically repoint routing rules from the OLD worker
    # URI to the NEW one inside ONE Repo.transaction (round-4 KEPT).
    # On failure: the transaction rolls back so the DB names the OLD
    # worker; a re-invocation re-attempts the repoint. The new worker
    # stays alive (reconciler model — not an orphan, valid intermediate
    # state).
    {pending, errors} =
      case repoint_routing_rules(old_worker_uri, new_worker_uri) do
        :ok ->
          {pending, errors}

        {:error, reason} ->
          {[:routing | pending], [{:routing, reason} | errors]}
      end

    # Step 3 — commit the slot tuple to the new template + worker +
    # bumped generation. Wrapped against the Session-Kind GenServer.call
    # exiting (round-6 MEDIUM-2 wrap retained — `{:uncertain, _}`
    # surfaces as a `:partial` error, not a crash).
    {slot_outcome, pending, errors} =
      case commit_slot_step2(
             session_uri,
             slot_name,
             new_template_uri,
             new_worker_uri,
             new_generation,
             caller,
             caps
           ) do
        :ok ->
          {:committed, pending, errors}

        {:error, reason} ->
          {:not_committed, [:slot | pending], [{:slot, reason} | errors]}

        {:uncertain, detail} ->
          {:uncertain, [:slot | pending], [{:slot, {:uncertain, detail}} | errors]}
      end

    # Step 4 — terminate the OLD worker — ONLY when routing AND slot
    # both confirm the new worker. Otherwise leave the OLD worker
    # alive (a re-invocation will reach this step when the preceding
    # steps converge).
    {pending, errors} =
      if pending == [] and slot_outcome == :committed do
        case maybe_terminate_old(old_worker_uri, new_worker_uri, caller, caps) do
          :ok ->
            {pending, errors}

          # PR3 round-2 MEDIUM-1 (codex) — distinct cleanup-failure
          # bucket. The OLD worker IS terminated (sandbox.destroy
          # always schedules termination), but its config dir leaked.
          # A retry of update_agent_template hits the no-op path
          # (slot already at new_worker), so the leak is NOT
          # auto-recovered. PR4 follow-up: persist an explicit
          # cleanup-required record so an ops dashboard / reconciler
          # tick can retry. For now, surface as a distinct error so
          # operator sees it (vs swallowing as :ok).
          {:error, {:terminated_with_cleanup_failure, reason}} ->
            {[:old_worker_config_cleanup | pending],
             [{:old_worker_config_cleanup, reason} | errors]}

          {:error, reason} ->
            {[:old_worker | pending], [{:old_worker, reason} | errors]}
        end
      else
        # Routing or slot didn't converge — keep both workers alive.
        {pending, errors}
      end

    case {pending, errors} do
      {[], []} ->
        {:ok, new_worker_uri}

      _ ->
        {:partial,
         %{
           slot: slot_name,
           new_worker_uri: new_worker_uri,
           old_worker_uri: old_worker_uri,
           pending: Enum.reverse(pending),
           errors: Enum.reverse(errors)
         }}
    end
  end

  # The step-3 slot commit, wrapped against an exiting `GenServer.call`.
  # The wrap is retained from round-6 MEDIUM-2 — a dead/timing-out
  # Session would otherwise EXIT the caller, breaking the reconciler's
  # `{:ok | :partial | :error}` discipline.
  #
  #   - `:ok`                  — the slot write VERIFIABLY committed;
  #   - `{:error, reason}`     — a tagged failure; the slot CONFIRMED
  #     did NOT commit;
  #   - `{:uncertain, detail}` — the call EXITED / raised; the slot
  #     write state is UNKNOWN. Reported as `:partial` so the next
  #     invocation re-evaluates.
  defp commit_slot_step2(
         %URI{} = session_uri,
         slot_name,
         %URI{} = new_template_uri,
         %URI{} = new_worker_uri,
         new_generation,
         %URI{} = caller,
         caps
       ) do
    try do
      case upsert_agent_slot(
             session_uri,
             slot_name,
             new_template_uri,
             new_worker_uri,
             new_generation,
             caller,
             caps
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:uncertain, {:slot_write_crashed, e}}
    catch
      kind, reason -> {:uncertain, {:slot_write_crashed, {kind, reason}}}
    end
  end

  # MEDIUM-3 (round 3) — the swap's slot-name uniqueness preflight.
  #
  # `update_agent_template` bumps ONE slot to a fresh generation. Its new
  # instance name (hence worker URI) must not collide with any OTHER live
  # slot's instance name.
  defp preflight_swap_uniqueness(%URI{} = session_uri, slot_name, new_generation, discriminator) do
    want = to_string(slot_name)

    slot_specs =
      read_template_working_copy(session_uri)
      |> Map.get(:agent_slots, [])
      |> Enum.map(&normalize_slot/1)
      |> Enum.flat_map(fn
        {^want, _src, _worker, _gen} -> [{want, new_generation}]
        {name, _src, _worker, gen} when is_binary(name) and is_integer(gen) -> [{name, gen}]
        _ -> []
      end)

    Ezagent.Orchestrator.SlotNames.preflight(slot_specs, discriminator)
  end

  # Preflight: dispatch `template.read` on the new AgentTemplate URI,
  # cap-checked (cap #4). Confirms the template exists + is populated
  # BEFORE any destructive step.
  defp preflight_template_read(%URI{} = agent_template_uri, %URI{} = caller, caps) do
    with {:ok, _pid} <- ensure_template_alive(agent_template_uri),
         target <- URI.parse("#{URI.to_string(agent_template_uri)}?action=template.read"),
         {:ok, result} <-
           Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{},
             ctx: ctx(caller, caps)
           }) do
      case result do
        %{content: content} when is_map(content) -> {:ok, content}
        %{content: nil} -> {:error, :agent_template_not_populated}
        other -> {:error, {:unexpected_template_read_result, other}}
      end
    end
  end

  # MEDIUM-3 (round 4) — reject the swap if the candidate replacement
  # worker URI is ALREADY live in `KindRegistry` as an orphan.
  defp preflight_candidate_uri_free(
         new_template_content,
         instance_name,
         %URI{} = workspace_uri,
         %URI{} = old_worker_uri
       ) do
    case candidate_worker_uri(new_template_content, instance_name, workspace_uri) do
      {:ok, %URI{} = candidate_uri} ->
        Ezagent.Orchestrator.SlotNames.preflight_live_worker_uris([
          {candidate_uri, old_worker_uri}
        ])

      :no_flavor ->
        :ok
    end
  end

  # Build the full worker URI `template.instantiate` would construct:
  # `entity://agent/<workspace>/<flavor>_<instance_name>`. Returns
  # `:no_flavor` if the content has no flavor (the URI is then
  # underivable — `instantiate_worker` will surface the flavor error).
  defp candidate_worker_uri(content, instance_name, %URI{} = workspace_uri)
       when is_binary(instance_name) do
    flavor = Map.get(content, :flavor) || Map.get(content, "flavor")
    workspace_name = workspace_uri.host || "default"

    if is_binary(flavor) and flavor != "" do
      {:ok, URI.new!("entity://agent/#{workspace_name}/#{flavor}_#{instance_name}")}
    else
      :no_flavor
    end
  end

  # codex round-5 MEDIUM-3 — the swap path must NEVER silently adopt an
  # already-live worker.
  defp require_fresh_candidate({:ok, %{fresh?: true}} = ok), do: ok

  defp require_fresh_candidate({:ok, %{fresh?: false}}),
    do: {:error, :candidate_uri_already_live}

  defp require_fresh_candidate({:error, _} = err), do: err

  # === routing rule prune / repoint (KEPT — round-4 atomic-repoint primitive) ===

  # Reconciler step in `remove_agent_slot`: drop the worker URI from
  # every routing rule's receiver set inside ONE `Repo.transaction`.
  # Rules left with zero receivers are also removed (no stale empty
  # rules).
  defp prune_routing_rules_for(%URI{} = worker_uri) do
    table = EzagentDomainChat.Routing.MentionRouting
    worker_str = URI.to_string(worker_uri)

    txn =
      EzagentCore.Repo.transaction(fn ->
        rules = Ezagent.Routing.RuleStore.list(table)

        rules
        |> Enum.filter(fn rule -> worker_str in (rule.receivers || []) end)
        |> Enum.each(fn rule ->
          remaining =
            (rule.receivers || [])
            |> Enum.reject(fn r -> r == worker_str end)
            |> Enum.uniq()

          result =
            if remaining == [] do
              Ezagent.Routing.RuleStore.delete(rule.id, force: true)
            else
              Ezagent.Routing.RuleStore.update_receivers(rule.id, remaining, rule.enabled)
            end

          case result do
            :ok -> :ok
            {:error, reason} -> EzagentCore.Repo.rollback({:prune_failed, reason})
          end
        end)

        :ok
      end)

    case txn do
      {:ok, :ok} ->
        reload_registry(table)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:prune_failed, e}}
  catch
    kind, reason -> {:error, {:prune_failed, {kind, reason}}}
  end

  # HIGH-1 (round 4) — rewrite every routing rule whose receivers name
  # `old_worker_uri` so they point at `new_worker_uri` instead, inside
  # ONE `Repo.transaction`. KEPT verbatim — the round-4 atomicity
  # invariant survives the reconciler model (a partial repoint is
  # observable; the swap of two receiver URIs must be atomic at the
  # routing layer).
  #
  # On rollback the persisted rows are atomically restored to the OLD
  # worker URI. The reconciler treats that as expected intermediate
  # state — the new worker stays alive (a re-invocation re-attempts the
  # repoint). There is no inverse-revert machinery; the next pass IS
  # the recovery.
  #
  # Idempotent: a rule with no `old` receiver is left alone; a rule that
  # has BOTH `old` and `new` is collapsed (the new URI appears once).
  @spec repoint_routing_rules(URI.t(), URI.t()) :: :ok | {:error, term()}
  defp repoint_routing_rules(%URI{} = old_worker_uri, %URI{} = new_worker_uri) do
    table = EzagentDomainChat.Routing.MentionRouting
    old_str = URI.to_string(old_worker_uri)
    new_str = URI.to_string(new_worker_uri)

    case rewrite_receivers_txn(table, old_str, new_str) do
      {:ok, []} ->
        :ok

      {:ok, _changed_ids} ->
        reload_registry(table)

      {:error, _} = err ->
        err
    end
  end

  # The forward transaction: rewrite every `old_str`-naming rule to
  # `new_str` inside ONE `Repo.transaction`. Returns `{:ok, [rule_id]}`
  # — the row IDs the transaction changed — or `{:error, reason}`
  # (rolled back, DB untouched).
  defp rewrite_receivers_txn(table, old_str, new_str) do
    txn =
      EzagentCore.Repo.transaction(fn ->
        rules = Ezagent.Routing.RuleStore.list(table)

        rules
        |> Enum.filter(fn rule -> old_str in (rule.receivers || []) end)
        |> Enum.reduce_while([], fn rule, changed_ids ->
          new_receivers =
            rule.receivers
            |> Enum.map(fn r -> if r == old_str, do: new_str, else: r end)
            |> Enum.uniq()

          case Ezagent.Routing.RuleStore.update_receivers(rule.id, new_receivers, rule.enabled) do
            :ok ->
              {:cont, [rule.id | changed_ids]}

            {:error, reason} ->
              EzagentCore.Repo.rollback({:repoint_failed, reason})
          end
        end)
      end)

    case txn do
      {:ok, changed_ids} -> {:ok, Enum.reverse(changed_ids)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:repoint_failed, e}}
  catch
    kind, reason -> {:error, {:repoint_failed, {kind, reason}}}
  end

  # The registry reload — captured: a raise (e.g.
  # `RoutingRegistry.get_meta/1` raising for an undeclared table)
  # becomes a tagged `{:error, _}`.
  defp reload_registry(table) do
    Ezagent.Routing.RuleStore.load_into_registry(table)
    :ok
  rescue
    e -> {:error, {:registry_reload_failed, e}}
  catch
    _, reason -> {:error, {:registry_reload_failed, reason}}
  end

  # Terminate the OLD worker after a successful convergence.
  defp maybe_terminate_old(%URI{} = old_worker_uri, %URI{} = new_worker_uri, caller, caps) do
    if URI.to_string(old_worker_uri) == URI.to_string(new_worker_uri) do
      :ok
    else
      case terminate_worker(old_worker_uri, caller, caps) do
        :ok ->
          :ok

        {:error, reason} ->
          # Logged but non-fatal — the new worker is live, routing +
          # slot already point at it. A stale OLD process is a
          # cosmetic leak; flag as :pending in the partial outcome but
          # don't fail the whole tool.
          Logger.warning(
            "update_agent_template: new worker live, but terminating old worker " <>
              "#{URI.to_string(old_worker_uri)} failed: #{inspect(reason)} — stale process left"
          )

          {:error, reason}
      end
    end
  end

  # === write_matcher =====================================================

  @doc """
  Insert a routing rule that fires `matcher_ast` and delivers to the
  workers named by `receiver_slot_names`, by dispatching
  `Ezagent.Behavior.Routing` `:add_rule` on the orchestrator's Session
  URI (SPEC §2.1 row 4).

  The rule's scope-owning Kind is the orchestrator's Session (invariant
  12 — no `routing-admin://` singleton). CapBAC: gated by cap #1
  (`{:within_session, S}`).

  Receiver slot names are resolved to per-instance worker URIs from the
  durable `template_working_copy.agent_slots`.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, %{id: integer}}` or `{:error, reason}`.
  """
  @spec write_matcher(term(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def write_matcher(matcher_ast, receiver_slot_names, opts \\ [])
      when is_list(receiver_slot_names) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, matcher_json} <- normalize_matcher(matcher_ast),
         {:ok, receiver_uris} <-
           resolve_receiver_uris(session_uri, receiver_slot_names, workspace_uri) do
      target = URI.parse("#{URI.to_string(session_uri)}?action=routing.add_rule")

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{
               table: EzagentDomainChat.Routing.MentionRouting,
               matcher_json: matcher_json,
               receivers: Enum.map(receiver_uris, &URI.to_string/1),
               opts: [workspace_uri: workspace_uri, source: "admin"]
             },
             ctx: ctx(caller, caps)
           }) do
        {:ok, %{id: id}} -> {:ok, %{id: id}}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_add_rule_result, other}}
      end
    end
  end

  # Normalize the matcher into the JSON shape `routing.add_rule` expects.
  defp normalize_matcher(%{} = matcher_json) do
    case Ezagent.Routing.Matcher.from_json(matcher_json) do
      {:ok, _} -> {:ok, matcher_json}
      {:error, _} = err -> err
    end
  end

  defp normalize_matcher(matcher_tuple) when is_tuple(matcher_tuple) do
    json = Ezagent.Routing.Matcher.to_json(matcher_tuple)
    {:ok, json}
  rescue
    _ -> {:error, {:invalid_matcher, matcher_tuple}}
  end

  defp normalize_matcher(other), do: {:error, {:invalid_matcher, other}}

  # === update_template ===================================================

  @doc """
  Snapshot the live session as a NEW VERSION of the current parent
  SessionTemplate, persisting it via
  `Ezagent.Entity.SessionTemplate.persist_version/3` (SPEC §2.1 row 5).

  ## CapBAC — HIGH-9 hardening

  The tool runs `check_template_write_cap/2` (cap #3, `:session_template`,
  `{:within_workspace, ws}`) at the boundary, AND threads the
  orchestrator's `{caller, caps}` into `persist_version/3` so the
  decisive `template.write` dispatch is CapBAC-checked against the
  ORCHESTRATOR's real authority — NOT `admin_caps`.

  Required `opts`: `:caller`, `:caps`, `:session_uri`, `:workspace_uri`,
  `:parent_template_uri`.

  Returns `{:ok, new_template_uri}` —
  `template://session/<workspace>/<parent_name>@<new_hash>`. If the
  parent SessionTemplate hash has been deleted, returns
  `{:error, :parent_template_deleted}` (use `save_template_as`).
  """
  @spec update_template(keyword()) :: {:ok, URI.t()} | {:error, term()}
  def update_template(opts \\ []) do
    with {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, %URI{} = parent_uri} <- require_opt(opts, :parent_template_uri),
         :ok <- check_template_write_cap(caps, workspace_uri),
         :ok <- check_parent_alive(parent_uri),
         {:ok, parent_name} <- extract_template_name(parent_uri),
         {:ok, slice} <- build_working_copy(session_uri, workspace_uri, caller_uri, parent_uri) do
      content =
        slice
        |> Map.put(:name, parent_name)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())

      SessionTemplate.persist_version(content, workspace_uri,
        caller: caller_uri,
        caps: caps
      )
    end
  end

  # Phase 7 PR 48 + HIGH-8 hardening — parent-template-deletion check
  # against the durable store.
  defp check_parent_alive(%URI{} = parent_uri) do
    cond do
      match?({:ok, _pid}, Ezagent.KindRegistry.lookup(parent_uri)) ->
        :ok

      durable_snapshot_exists?(parent_uri) ->
        :ok

      true ->
        {:error, :parent_template_deleted}
    end
  end

  defp durable_snapshot_exists?(%URI{} = uri) do
    case Ezagent.Ecto.KindSnapshot.get(URI.to_string(uri)) do
      %Ezagent.Ecto.KindSnapshot{} -> true
      nil -> false
    end
  rescue
    _ -> false
  end

  # === save_template_as ==================================================

  @doc """
  Snapshot the live session as the FIRST VERSION of a NEW SessionTemplate
  named `new_name`, persisting it via
  `Ezagent.Entity.SessionTemplate.persist_version/3` (SPEC §2.1 row 6).

  HIGH-9 — the `template.write` persistence dispatch runs under the
  orchestrator's threaded `{caller, caps}`, NOT `admin_caps`.

  Required `opts`: same as `update_template/1` except
  `:parent_template_uri` is optional (the new template records it as
  lineage when present). `:owner` — the principal who should receive the
  template-create cap (defaults to `:caller` when absent).

  Returns `{:ok, new_template_uri}`.
  """
  @spec save_template_as(String.t(), keyword()) :: {:ok, URI.t()} | {:error, term()}
  def save_template_as(new_name, opts \\ []) when is_binary(new_name) and new_name != "" do
    parent_uri =
      case Keyword.get(opts, :parent_template_uri) do
        %URI{} = u -> u
        _ -> nil
      end

    with {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         :ok <- check_template_write_cap(caps, workspace_uri),
         {:ok, slice} <- build_working_copy(session_uri, workspace_uri, caller_uri, parent_uri) do
      content =
        slice
        |> Map.put(:name, new_name)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())

      case SessionTemplate.persist_version(content, workspace_uri,
             caller: caller_uri,
             caps: caps
           ) do
        {:ok, new_uri} ->
          owner_uri = Keyword.get(opts, :owner, caller_uri)
          :ok = grant_owner_template_cap(owner_uri, new_uri, workspace_uri)
          {:ok, new_uri}

        {:error, _} = err ->
          err
      end
    end
  end

  # SPEC §1.7 (e) — after creating a new SessionTemplate, grant the
  # owner a `Behavior.Template` cap on `:session_template` for the
  # workspace so they may later instantiate it.
  defp grant_owner_template_cap(
         %URI{} = owner_uri,
         %URI{} = _new_template_uri,
         %URI{} = workspace_uri
       ) do
    cap = %Ezagent.Capability{
      kind: :session_template,
      behavior: Ezagent.Behavior.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: DateTime.utc_now()
    }

    target = URI.parse("#{URI.to_string(owner_uri)}?action=identity.grant_cap")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{cap: cap},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: :ignore
           }
         }) do
      {:ok, _} ->
        :ok

      other ->
        # Non-fatal: the template exists; the cap can be re-granted.
        Logger.warning(
          "save_template_as: owner template-cap grant failed: #{inspect(other)} — " <>
            "template persisted; owner may need a re-grant to instantiate it"
        )

        :ok
    end
  end

  # === list_templates ====================================================

  @doc """
  List visible templates as
  `%{agent_templates: [URI.t()], session_templates: [URI.t()]}`,
  per-kind cap-gated (SPEC §2.1 row 7 / §1.7 (b)).

  Required `opts`: `:caps`, `:workspace_uri`.

  Optional `name_filter` — substring restricts results.
  """
  @spec list_templates(String.t() | nil, keyword()) ::
          {:ok, %{agent_templates: [URI.t()], session_templates: [URI.t()]}}
          | {:error, term()}
  def list_templates(name_filter \\ nil, opts \\ []) do
    with {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri) do
      agent_allowed? = has_template_cap?(caps, :agent_template, workspace_uri)
      session_allowed? = has_template_cap?(caps, :session_template, workspace_uri)

      if not agent_allowed? and not session_allowed? do
        {:error, :unauthorized}
      else
        rows = snapshot_rows_in_workspace(workspace_uri)

        agents =
          if agent_allowed?,
            do: filter_rows(rows, "agent_template", "agent", name_filter),
            else: []

        sessions =
          if session_allowed?,
            do: filter_rows(rows, "session_template", "session", name_filter),
            else: []

        {:ok, %{agent_templates: agents, session_templates: sessions}}
      end
    end
  end

  defp snapshot_rows_in_workspace(%URI{} = workspace_uri) do
    Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)
  rescue
    _ -> []
  end

  defp filter_rows(rows, kind_type, expected_host, name_filter) do
    rows
    |> Enum.filter(fn row -> row.kind_type == kind_type end)
    |> Enum.map(fn row -> URI.parse(row.uri) end)
    |> Enum.filter(&template_match?(&1, expected_host, name_filter))
    |> Enum.sort_by(&URI.to_string/1)
  end

  # === generic invoke ====================================================

  @doc """
  Generic tool invocation entry — dispatches by tool name to the
  corresponding function above.
  """
  @spec invoke(atom(), list()) :: {:ok, term()} | {:error, term()}
  def invoke(tool_name, args) when is_atom(tool_name) and is_list(args) do
    if tool?(tool_name) do
      apply(__MODULE__, tool_name, args)
    else
      {:error, {:unknown_tool, tool_name}}
    end
  end

  # === internals =========================================================

  defp ctx(%URI{} = caller, caps) do
    %{
      caller: caller,
      caps: to_cap_set(caps),
      reply: {:caller_inbox, self()}
    }
  end

  defp to_cap_set(%MapSet{} = caps), do: caps
  defp to_cap_set(caps) when is_list(caps), do: MapSet.new(caps)
  defp to_cap_set(_), do: MapSet.new()

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_opt, key}}
      v -> {:ok, v}
    end
  end

  defp ensure_template_alive(%URI{} = template_uri) do
    case Ezagent.KindRegistry.lookup(template_uri) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case Ezagent.SpawnRegistry.spawn(template_uri) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  defp has_template_cap?(caps, kind, %URI{} = workspace_uri) do
    workspace_name = workspace_uri.host || "default"

    representative =
      case kind do
        :agent_template -> URI.new!("template://agent/#{workspace_name}/_catalog")
        :session_template -> URI.new!("template://session/#{workspace_name}/_catalog@_")
      end

    needed = %{
      kind: kind,
      behavior: Ezagent.Behavior.Template,
      instance: representative,
      workspace_uri: workspace_uri
    }

    caps
    |> to_cap_set()
    |> Enum.any?(&Ezagent.Capability.matches?(&1, needed))
  end

  defp check_template_write_cap(caps, %URI{} = workspace_uri) do
    if has_template_cap?(caps, :session_template, workspace_uri) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp template_match?(%URI{scheme: "template", host: host} = uri, expected_host, nil) do
    host == expected_host and is_binary(uri.path)
  end

  defp template_match?(
         %URI{scheme: "template", host: _host, path: path} = uri,
         expected_host,
         filter
       )
       when is_binary(filter) do
    template_match?(uri, expected_host, nil) and
      (path != nil and String.contains?(path, filter))
  end

  defp template_match?(_, _, _), do: false

  defp extract_template_name(%URI{scheme: "template", host: "session", path: path})
       when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [_workspace, name_with_hash | _] ->
        name = name_with_hash |> String.split("@") |> hd()

        if name == "" do
          {:error, :template_name_empty}
        else
          {:ok, name}
        end

      _ ->
        {:error, :template_name_empty}
    end
  end

  defp extract_template_name(other), do: {:error, {:not_a_session_template_uri, other}}

  # --- working-copy slice maintenance (SPEC §1.6) ------------------------

  defp upsert_agent_slot(
         %URI{} = session_uri,
         slot_name,
         %URI{} = agent_template_uri,
         %URI{} = worker_uri,
         generation,
         %URI{} = caller,
         caps
       )
       when is_integer(generation) and generation >= 0 do
    wc = read_template_working_copy(session_uri)
    slots = Map.get(wc, :agent_slots, [])

    new_slots =
      slots
      |> reject_slot(slot_name)
      |> Kernel.++([{slot_name, agent_template_uri, worker_uri, generation}])

    write_working_copy(session_uri, Map.put(wc, :agent_slots, new_slots), caller, caps)
  end

  defp drop_agent_slot(%URI{} = session_uri, slot_name, %URI{} = caller, caps) do
    wc = read_template_working_copy(session_uri)
    slots = Map.get(wc, :agent_slots, [])

    write_working_copy(
      session_uri,
      Map.put(wc, :agent_slots, reject_slot(slots, slot_name)),
      caller,
      caps
    )
  end

  defp reject_slot(slots, slot_name) do
    Enum.reject(slots, fn tuple -> slot_tuple_name(tuple) == to_string(slot_name) end)
  end

  defp slot_tuple_name(tuple) when is_tuple(tuple) and tuple_size(tuple) >= 1 do
    to_string(elem(tuple, 0))
  end

  defp slot_tuple_name(_), do: nil

  defp write_working_copy(%URI{} = session_uri, working_copy, %URI{} = caller, caps) do
    target = URI.parse("#{URI.to_string(session_uri)}?action=chat.set_working_copy")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{template_working_copy: working_copy},
           ctx: ctx(caller, caps)
         }) do
      {:ok, %{template_working_copy: _}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  defp find_slot_tuple(%URI{} = session_uri, slot_name) do
    want = to_string(slot_name)

    read_template_working_copy(session_uri)
    |> Map.get(:agent_slots, [])
    |> Enum.find_value(fn tuple ->
      case normalize_slot(tuple) do
        {^want, _src, _worker, _gen} = t -> t
        _ -> nil
      end
    end)
  end

  defp normalize_slot({name, src, %URI{} = worker, gen})
       when is_integer(gen),
       do: {to_string(name), as_uri(src), worker, gen}

  defp normalize_slot({name, src, %URI{} = worker}),
    do: {to_string(name), as_uri(src), worker, 0}

  defp normalize_slot({name, src}),
    do: {to_string(name), as_uri(src), nil, 0}

  defp normalize_slot(other), do: other

  defp as_uri(%URI{} = u), do: u
  defp as_uri(s) when is_binary(s), do: URI.parse(s)
  defp as_uri(other), do: other

  defp resolve_slot_worker_uri(%URI{} = session_uri, slot_name, %URI{} = _workspace_uri) do
    case find_slot_tuple(session_uri, slot_name) do
      {_s, _src, %URI{} = worker_uri, _gen} -> {:ok, worker_uri}
      _ -> :no_slot
    end
  end

  defp resolve_receiver_uris(%URI{} = session_uri, slot_names, %URI{} = workspace_uri) do
    uris =
      slot_names
      |> Enum.map(fn slot ->
        case resolve_slot_worker_uri(session_uri, to_string(slot), workspace_uri) do
          {:ok, worker_uri} -> worker_uri
          :no_slot -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if uris == [] do
      {:error, :no_resolvable_receivers}
    else
      {:ok, uris}
    end
  end

  # Phase 7 completion PR-2 (SPEC §1.3 / §1.6) — build the
  # template-shaped working-copy slice from the durable
  # `template_working_copy` field on the live Session's `:chat` slice.
  defp build_working_copy(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = _caller_uri,
         parent_uri
       ) do
    wc = read_template_working_copy(session_uri)

    orchestrator_template_uri =
      Map.get(wc, :orchestrator_template_uri) ||
        URI.parse("template://agent/system/cc-orchestrator")

    default_workspace_uri = Map.get(wc, :default_workspace_uri) || workspace_uri

    template_slots =
      wc
      |> Map.get(:agent_slots, [])
      |> Enum.map(fn tuple ->
        {name, src, _worker, _gen} = normalize_slot(tuple)
        {name, src}
      end)
      |> Enum.sort()

    slice = %{
      description: Map.get(wc, :description, ""),
      agent_slots: template_slots,
      orchestrator_template_uri: orchestrator_template_uri,
      routing_rules: Enum.sort(Map.get(wc, :routing_rules, [])),
      default_workspace_uri: default_workspace_uri,
      parent_template_uri: parent_uri
    }

    {:ok, slice}
  end

  # Read the durable `template_working_copy` field off the live Session
  # Kind's `:chat` slice. A Session not alive, or whose `:chat` slice
  # predates PR-2, yields the empty default.
  defp read_template_working_copy(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Chat.state_slice(), %{})

        Chat.template_working_copy(chat_slice)

      :error ->
        Chat.default_template_working_copy()
    end
  end
end

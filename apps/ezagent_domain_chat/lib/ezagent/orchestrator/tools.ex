defmodule Ezagent.Orchestrator.Tools do
  @moduledoc """
  Orchestrator MCP tool surface — the 7 tools the cc-orchestrator
  (Decision #136, SPEC §7-3) exposes to the LLM it hosts.

  ## The 7 tools

  | Tool | Args | Effect |
  |---|---|---|
  | `add_agent_slot` | slot_name, agent_template_uri, optional prompt_override | Spawns a worker agent from template |
  | `remove_agent_slot` | slot_name | Despawns the worker |
  | `update_agent_template` | slot_name, new_agent_template_uri | Replaces an agent slot's template (re-spawn) |
  | `write_matcher` | matcher_ast, receiver_slot_names | Inserts routing rule into the live RuleStore |
  | `update_template` | (no args) | Snapshot current session state → new version of current parent SessionTemplate |
  | `save_template_as` | new_name | Snapshot current session state → first version of NEW SessionTemplate |
  | `list_templates` | optional name_filter | Returns visible AgentTemplate + SessionTemplate URIs (CapBAC-filtered) |

  ## Phase 7 completion PR-5 — every tool action goes through dispatch + CapBAC

  Pre-PR-5 the tools called `Agent.spawn/4` / `RuleStore.add/5` /
  `DynamicSupervisor.terminate_child` DIRECTLY — bypassing dispatch +
  CapBAC entirely. PR-5 refactors all 7 per the SPEC §2.1 dispatch table:

  - `add_agent_slot` — dispatches `template.instantiate` on the
    AgentTemplate URI (`Ezagent.Behavior.Template` `:instantiate`).
  - `remove_agent_slot` — dispatches `lifecycle.terminate` on the
    worker's instance URI (`Ezagent.Behavior.Lifecycle` `:terminate`).
  - `update_agent_template` — **two-phase rollback-safe**: preflight
    `template.read` → spawn the replacement via `template.instantiate`
    → re-point the working-copy slot → `lifecycle.terminate` the OLD
    worker ONLY after success.
  - `write_matcher` — dispatches `routing.add_rule` on the
    orchestrator's Session URI (`Ezagent.Behavior.Routing` `:add_rule`).
  - `update_template` / `save_template_as` — persist via
    `Ezagent.Entity.SessionTemplate.persist_version/2`, which spawns the
    SessionTemplate Kind + dispatches `Behavior.Template` `:write`.
  - `list_templates` — a per-kind cap-gated read of
    `Ezagent.Ecto.KindSnapshot.list_in_workspace/1`.

  **NO `admin_caps` anywhere in the tool path.** Every dispatch `ctx`
  carries `caps: <the orchestrator's 4 delegated caps>` and `caller:
  <the orchestrator's URI>` — supplied by the orchestrator MCP server
  (`Ezagent.Orchestrator.McpServer`). If a delegated cap is missing the
  dispatch returns `{:error, :unauthorized}` — fail closed, never a
  fallback to ambient authority.

  ## Calling convention

  Every tool takes a trailing `opts` keyword list carrying the
  orchestrator's caller context:

      Tools.add_agent_slot("backend-dev",
        URI.parse("template://agent/default/cc-backend"),
        nil,
        caller: %URI{} = orchestrator_uri,
        caps: caps,
        session_uri: %URI{} = sess,
        workspace_uri: %URI{} = ws)

  Required keys per tool documented at each `@doc`. The orchestrator MCP
  server fills these in from its bound per-orchestrator context before
  invoking — the LLM never supplies caller / caps / session context.

  ## Design locks (CI-gated, see tools_test.exs)

  - Exactly 7 tools (locks against authority creep).
  - No `:fork` tool (Decision #141 — fork is a SessionTemplate
    registry verb, not an in-session orchestrator verb).
  - No `:grant_cap` tool (Decision #137 — cap delegation only
    happens at Generator boot, never mid-session).

  ## Working-copy derivation (Phase 7 completion PR-2 — SPEC §1.3 / §1.6)

  The `template_working_copy` field on the Session's `:chat` slice
  (`Ezagent.Behavior.Chat`) IS the durable source-template record. The
  agent-slot tools (`add_agent_slot` / `remove_agent_slot` /
  `update_agent_template`) maintain `template_working_copy.agent_slots`
  via the `chat.set_working_copy` dispatch.
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
  Spawn a worker agent in `slot_name` from `agent_template_uri`, by
  dispatching `Ezagent.Behavior.Template` `:instantiate` on the
  AgentTemplate URI (SPEC §2.1 row 1).

  The `:instantiate` action resolves the flavor Class and hands off to
  `Ezagent.Entity.Agent.spawn_from_template_content/4`, which records
  lineage UNDER THE ORCHESTRATOR (`spawned_by: caller`) — so the
  orchestrator's cap #2 (`{:spawned_by, orchestrator}`) later authorizes
  managing the worker.

  Required `opts`:
  - `:caller` — `%URI{}` of the orchestrator (the dispatch `ctx.caller`
    + the `spawned_by` principal for lineage)
  - `:caps` — the orchestrator's delegated cap set (cap #4 gates the
    `template.instantiate`)
  - `:workspace_uri` — `%URI{}` workspace the worker joins; must equal
    the AgentTemplate URI's workspace segment
  - `:session_uri` — `%URI{}` of the orchestrator's session (the
    `agent_slots` slice the worker is recorded into lives here)

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
         {:ok, session_uri} <- require_opt(opts, :session_uri),
         # CRITICAL/HIGH-6 hardening — the LIVE worker instance name is
         # session-unique (gen 0 for a fresh slot). Two sessions adding
         # the same slot name get DISJOINT live worker URIs.
         instance_name <-
           Ezagent.Entity.Agent.session_instance_name(
             slot_name,
             session_discriminator(session_uri),
             0
           ),
         {:ok, worker_uri} <-
           instantiate_worker(agent_template_uri, instance_name, workspace_uri, caller, caps) do
      # HIGH-7 saga — if recording the slot fails AFTER the worker
      # spawned, terminate the orphaned worker before surfacing the
      # error (a worker with lineage but no slot).
      case upsert_agent_slot(
             session_uri,
             slot_name,
             agent_template_uri,
             worker_uri,
             0,
             caller,
             caps
           ) do
        :ok ->
          {:ok, worker_uri}

        {:error, reason} ->
          compensate_orphan_worker(worker_uri, caller, caps, reason)
          {:error, {:add_agent_slot_aborted, reason}}
      end
    end
  end

  # Dispatch `template.instantiate` on the AgentTemplate Kind. The
  # action runs in-process with the slice in hand, resolves the flavor
  # Class, and spawns the worker — recording lineage under `caller`.
  # `instance_name` is the SESSION-UNIQUE live instance name (CRITICAL
  # fix) — the caller built it via `Agent.session_instance_name/3`.
  defp instantiate_worker(
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
        {:ok, %{workers: [worker_uri | _]}} -> {:ok, worker_uri}
        {:ok, %{workers: []}} -> {:error, :instantiate_returned_no_worker}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_instantiate_result, other}}
      end
    end
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

  # HIGH-7 — terminate a replacement/new worker orphaned because a
  # post-spawn saga step failed. Best-effort; a failed cleanup is
  # logged so the orphan is visible (it never silently lingers).
  defp compensate_orphan_worker(%URI{} = worker_uri, %URI{} = caller, caps, cause) do
    case terminate_worker(worker_uri, caller, caps) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "orchestrator saga cleanup FAILED — orphaned worker " <>
            "#{URI.to_string(worker_uri)} could not be terminated after " <>
            "#{inspect(cause)}: #{inspect(reason)} — manual cleanup required"
        )

        :ok
    end
  end

  # === remove_agent_slot =================================================

  @doc """
  Despawn the worker in `slot_name` by dispatching
  `Ezagent.Behavior.Lifecycle` `:terminate` on the worker's instance URI
  (SPEC §2.1 row 2).

  The worker's instance URI is resolved from the durable
  `template_working_copy.agent_slots` slice. An absent slot is
  idempotent success.

  CapBAC: `lifecycle.terminate` is gated by cap #2
  (`{:spawned_by, orchestrator}`) — the orchestrator may terminate only
  workers it itself spawned.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, :removed}` whether the slot was alive or not (idempotent).
  """
  @spec remove_agent_slot(String.t(), keyword()) :: {:ok, :removed} | {:error, term()}
  def remove_agent_slot(slot_name, opts \\ []) when is_binary(slot_name) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      case resolve_slot_worker_uri(session_uri, slot_name, workspace_uri) do
        {:ok, worker_uri} ->
          with :ok <- terminate_worker(worker_uri, caller, caps),
               :ok <- drop_agent_slot(session_uri, slot_name, caller, caps) do
            {:ok, :removed}
          end

        :no_slot ->
          # Absent slot — idempotent success (SPEC §2.1 error mapping).
          {:ok, :removed}
      end
    end
  end

  # Dispatch `lifecycle.terminate` on the worker's instance URI.
  defp terminate_worker(%URI{} = worker_uri, %URI{} = caller, caps) do
    target = URI.parse("#{URI.to_string(worker_uri)}?action=lifecycle.terminate")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: ctx(caller, caps)
         }) do
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
  Replace the AgentTemplate behind `slot_name` with `new_agent_template_uri`
  — **two-phase, rollback-safe** (SPEC §2.1 row 3, codex rev-5 HIGH-4).

  The pre-PR-5 code did `remove`-then-`add`; a bad new template left the
  slot with no live agent. PR-5 makes it rollback-safe:

  1. **preflight** — dispatch `template.read` on `new_agent_template_uri`,
     cap-checked (cap #4), assert it exists + is populated;
  2. **spawn** the replacement worker via `template.instantiate`;
  3. **atomic swap** — update the working-copy slot tuple to point at
     the new AgentTemplate URI;
  4. **re-point routing** — rewrite every routing rule naming the OLD
     worker to the NEW one (HIGH-1, a CHECKED step of the transaction);
  5. **only then** `lifecycle.terminate` the OLD worker.

  Any failure in (1)-(3) aborts — the OLD worker + slot are untouched,
  no outage. A failure in (4) (HIGH-1, round 3) ALSO aborts: the slot
  tuple + routing rows are rolled back to the OLD worker, the NEW orphan
  is terminated, and the OLD worker is KEPT ALIVE — never a stale route
  to a dead worker. A failure in (5) is non-fatal (the new worker is
  live, the slot + routing already point at it); the stale old worker is
  logged.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, new_worker_uri}` or `{:error, {:update_aborted, reason}}`.
  """
  @spec update_agent_template(String.t(), URI.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def update_agent_template(slot_name, %URI{} = new_agent_template_uri, opts \\ [])
      when is_binary(slot_name) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, _workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      # Capture the OLD slot tuple BEFORE any mutation so phase 4
      # terminates exactly the OLD worker, and the generation counter
      # advances from the slot's current generation.
      case find_slot_tuple(session_uri, slot_name) do
        nil ->
          {:error, {:update_aborted, :no_such_slot}}

        {_s, old_template_uri, %URI{} = old_worker_uri, old_generation} ->
          do_update_agent_template(
            slot_name,
            new_agent_template_uri,
            session_uri,
            old_template_uri,
            old_worker_uri,
            old_generation,
            caller,
            caps
          )

        # HIGH-4 (round 2) — a pre-hardening 2-tuple `{name, src}` slot
        # widens (via `normalize_slot/1`) to `{name, src, nil, 0}`: a
        # slot with NO recorded live worker URI. The pre-round-2 `case`
        # had no clause for `{_, _, nil, _}`, so a legacy snapshot's
        # slot crashed `update_agent_template` with a `CaseClauseError`
        # instead of a controlled error. An explicit clause returns a
        # structured `:no_live_worker` error — the orchestrator can then
        # `remove_agent_slot` + `add_agent_slot` to re-establish a live
        # worker. (A respawn-from-source path was considered; a clear
        # error is safer — the legacy slot's `src` may itself be stale,
        # and the orchestrator should make the re-add decision
        # explicitly rather than the swap silently resurrecting it.)
        {_s, _old_template_uri, nil, _old_generation} ->
          {:error, {:update_aborted, :no_live_worker}}
      end
    end
  end

  # HIGH-6 + HIGH-7 + HIGH-1 — the transactional, rollback-safe swap.
  #
  # HIGH-6: the replacement worker spawns under a fresh
  # **generation-specific** instance URI (`old_generation + 1`). The
  # pre-hardening code reused the same `{workspace, flavor, slot_name}`
  # URI, so a cc→cc swap produced an identical URI — the cc Class
  # treated the already-alive worker as idempotent success and the OLD
  # process kept running with the OLD config. A generation-bumped URI
  # is genuinely new, so the worker actually restarts.
  #
  # HIGH-7: if `upsert_agent_slot` (the slot-tuple commit) fails AFTER
  # the replacement spawned, the new worker is an orphan (lineage, no
  # slot); `compensate_orphan_worker/4` terminates it before the error
  # is surfaced. The OLD worker + routing stay untouched — no outage.
  #
  # HIGH-1 (round 4): the routing re-point is now a SQL TRANSACTION, not
  # a multi-step manual abort path. `RuleStore` rows store CONCRETE
  # receiver URIs, not slot names — so after the slot tuple is swapped
  # the existing routing rules still name `old_worker_uri`. The swap
  # rewrites every such row to `new_worker_uri`; the whole rewrite runs
  # inside ONE `Repo.transaction` (`repoint_routing_rules/2`). On ANY
  # failure `Repo.rollback` atomically restores every row to the OLD
  # worker URI — there is no partial routing state to compensate for.
  #
  # The swap is sequenced so no step terminates the old worker until
  # BOTH routing AND the slot consistently name the new worker:
  #
  #   1. spawn the replacement worker;
  #   2. `upsert_agent_slot` — commit the slot tuple to the new worker.
  #      A failure here orphans the new worker → `compensate_orphan_worker`
  #      terminates it; OLD worker + routing untouched (HIGH-7);
  #   3. `repoint_routing_rules` — rewrite the routing rows inside a
  #      `Repo.transaction`. On rollback the persisted rows are
  #      atomically back on the OLD worker; the swap ABORTS — the slot
  #      tuple is reverted to the OLD worker (one call — the slot is a
  #      Session-Kind slice, not in the SQL transaction), the NEW orphan
  #      is terminated, the OLD worker is KEPT ALIVE + still routed-to;
  #   4. only after BOTH committed: `load_into_registry` reflects the
  #      committed rows in ETS, then the OLD worker is terminated.
  #
  # The transaction IS the routing rollback — the round-3 manual
  # `abort_swap_on_repoint_failure` / `revert_routing_rules` are gone.
  defp do_update_agent_template(
         slot_name,
         %URI{} = new_agent_template_uri,
         %URI{} = session_uri,
         old_template_uri,
         %URI{} = old_worker_uri,
         old_generation,
         %URI{} = caller,
         caps
       ) do
    new_generation = old_generation + 1
    workspace_uri = derive_workspace(session_uri)
    discriminator = session_discriminator(session_uri)

    instance_name =
      Ezagent.Entity.Agent.session_instance_name(
        slot_name,
        discriminator,
        new_generation
      )

    with :ok <-
           preflight_swap_uniqueness(session_uri, slot_name, new_generation, discriminator),
         {:ok, new_template_content} <-
           preflight_template_read(new_agent_template_uri, caller, caps),
         # MEDIUM-3 (round 4) — the candidate replacement worker URI must
         # not ALREADY be live as an orphan. A prior failed swap may have
         # left a worker spawned at this exact generation-specific URI; a
         # retry recomputes the same name, so without this check
         # `instantiate_worker` would hit plugin idempotency and silently
         # adopt the stale worker. The expected-URI is the OLD worker
         # (the only legitimately-live worker for this slot before the
         # swap) — a degenerate same-URI case is therefore not a false
         # positive. Done AFTER reading the new template content, before
         # `instantiate_worker`.
         :ok <-
           preflight_candidate_uri_free(
             new_template_content,
             instance_name,
             workspace_uri,
             old_worker_uri
           ),
         # Step 1 — spawn the replacement worker under the fresh
         # generation-specific URI (cap #4).
         {:ok, new_worker_uri} <-
           instantiate_worker(new_agent_template_uri, instance_name, workspace_uri, caller, caps) do
      # Step 2 — commit the slot tuple to the new AgentTemplate URI, the
      # new LIVE worker URI, and the bumped generation. HIGH-7 — a
      # failure here orphans the new worker; OLD worker + routing
      # untouched.
      case upsert_agent_slot(
             session_uri,
             slot_name,
             new_agent_template_uri,
             new_worker_uri,
             new_generation,
             caller,
             caps
           ) do
        :ok ->
          # Step 3 — re-point every routing rule from the OLD worker URI
          # to the NEW one inside a Repo.transaction. On rollback the
          # rows are atomically restored to the OLD worker.
          case repoint_routing_rules(old_worker_uri, new_worker_uri) do
            :ok ->
              # Step 4 — routing + slot both name the NEW worker;
              # terminate the OLD worker. The new worker has a DIFFERENT
              # URI (generation-bumped), so this always terminates a
              # genuinely-distinct old process.
              maybe_terminate_old(old_worker_uri, new_worker_uri, caller, caps)
              {:ok, new_worker_uri}

            {:error, reason} ->
              # HIGH-1 — the routing transaction rolled back: the
              # persisted rows are already atomically back on the OLD
              # worker. The swap ABORTS — revert the slot tuple to the
              # OLD worker (one call — the slot is a Session-Kind slice,
              # not in the SQL transaction), terminate the NEW orphan,
              # keep the OLD worker alive + still routed-to.
              abort_swap_after_repoint_rollback(
                slot_name,
                session_uri,
                old_template_uri,
                old_worker_uri,
                new_worker_uri,
                old_generation,
                caller,
                caps,
                reason
              )
          end

        {:error, reason} ->
          compensate_orphan_worker(new_worker_uri, caller, caps, reason)
          {:error, {:update_aborted, reason}}
      end
    else
      {:error, reason} ->
        # Phases 1-2 failed — the OLD slot is untouched, no outage.
        {:error, {:update_aborted, reason}}
    end
  end

  # MEDIUM-3 (round 3) — the swap's slot-name uniqueness preflight.
  #
  # `update_agent_template` bumps ONE slot to a fresh generation. Its new
  # instance name (hence worker URI) must not collide with any OTHER live
  # slot's instance name. `Ezagent.Orchestrator.SlotNames.preflight/2`
  # computes the whole candidate set — the swapped slot at
  # `new_generation` plus every other slot at its CURRENT generation —
  # and rejects the swap if any two collide, BEFORE the replacement
  # worker spawns. Uniqueness is guaranteed, not probabilistic.
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
  # BEFORE any destructive step. Returns `{:ok, content}` so the caller
  # can extract the flavor for the MEDIUM-3 candidate-URI check.
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
  #
  # The candidate worker URI is `entity://agent/<workspace>/<flavor>_<name>`
  # — exactly what `template.instantiate` would build. The `flavor` comes
  # from the new AgentTemplate's content. `expected_uri` is the OLD
  # worker (the slot's only legitimately-live worker before the swap), so
  # a degenerate generation-collision is not a false positive.
  #
  # A content missing a flavor is left to `instantiate_worker` to error
  # on (the flavor lookup) — the candidate URI can't be derived without
  # one, so the orphan check is vacuously `:ok`.
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

  # HIGH-1 (round 4) — rewrite every routing rule whose receivers name
  # `old_worker_uri` so they point at `new_worker_uri` instead, inside
  # ONE `Repo.transaction`.
  #
  # `RuleStore` rows store concrete receiver URI strings (not slot
  # names). When `update_agent_template` swaps a worker, the old worker
  # URI is terminated but any routing rule that named it still does —
  # the next matching message would route to a dead actor. This rewrites
  # every persisted rule; on success `load_into_registry/1` makes the
  # live `RoutingRegistry` ETS reflect the change, so the very next
  # message routes to the new worker.
  #
  # ## The transaction IS the rollback (no manual revert)
  #
  # The pre-round-4 code rewrote rows one-by-one and, on a failure,
  # walked a manual "revert" path that rewrote them back — itself not
  # failure-safe. The whole `RuleStore.update_receivers/3` batch now runs
  # inside `EzagentCore.Repo.transaction/1` (`RuleStore` is
  # `EzagentCore.Repo`-backed). On ANY failure — a tagged error OR an
  # exception — `Repo.rollback/1` atomically restores EVERY row to the
  # OLD worker URI. There is no partially-rewritten state to compensate
  # for. `load_into_registry/1` runs ONLY after the transaction commits,
  # so ETS only ever reflects committed rows.
  #
  # Returns `:ok` only when EVERY `old`-naming row was rewritten AND the
  # post-commit registry reload succeeded; a transaction rollback OR a
  # reload failure short-circuits to `{:error, reason}` so the caller
  # aborts the swap and keeps the old worker alive.
  #
  # ## The post-commit reload-failure window
  #
  # `load_into_registry/1` is an ETS op — it cannot join the SQL
  # transaction. If it fails AFTER the rewrite transaction committed,
  # the DB rows name the NEW worker but ETS still names the OLD one (the
  # reload never ran). The swap is aborting (the OLD worker stays the
  # truth), so the committed DB rows are restored to the OLD worker via
  # the INVERSE `Repo.transaction` — one symmetric atomic revert, not a
  # multi-step manual compensation. The DB then matches ETS (both name
  # the OLD worker) and the abort is fully consistent.
  #
  # Idempotent: a rule with no `old` receiver is left alone; a rule that
  # has BOTH `old` and `new` is collapsed (the new URI appears once).
  @spec repoint_routing_rules(URI.t(), URI.t()) :: :ok | {:error, term()}
  defp repoint_routing_rules(%URI{} = old_worker_uri, %URI{} = new_worker_uri) do
    table = EzagentDomainChat.Routing.MentionRouting
    old_str = URI.to_string(old_worker_uri)
    new_str = URI.to_string(new_worker_uri)

    case rewrite_receivers_txn(table, old_str, new_str) do
      {:ok, 0} ->
        # No row named the old worker — nothing rewritten, nothing to
        # reload.
        :ok

      {:ok, _rewritten} ->
        # The transaction committed; reflect the committed rows in the
        # live ETS.
        case reload_registry(table) do
          :ok ->
            :ok

          {:error, reload_reason} ->
            # The post-commit reload failed — the DB names the new
            # worker but ETS still names the old. The swap is aborting,
            # so restore the DB rows to the OLD worker via the inverse
            # transaction. DB + ETS then both name the OLD worker.
            _ = rewrite_receivers_txn(table, new_str, old_str)
            {:error, reload_reason}
        end

      {:error, _} = err ->
        # The transaction rolled back — every row is atomically back on
        # the OLD worker. The live registry was never touched.
        err
    end
  end

  # HIGH-1 (round 4) — rewrite every `old_str`-naming rule to `new_str`
  # inside ONE `Repo.transaction`. Any mid-batch failure (a tagged error
  # from `RuleStore.update_receivers/3` OR an exception) calls
  # `Repo.rollback/1`, atomically restoring every row to the OLD worker
  # URI. Returns `{:ok, rewritten_count}` (committed) or
  # `{:error, reason}` (rolled back — DB untouched).
  defp rewrite_receivers_txn(table, old_str, new_str) do
    txn =
      EzagentCore.Repo.transaction(fn ->
        rules = Ezagent.Routing.RuleStore.list(table)

        rules
        |> Enum.filter(fn rule -> old_str in (rule.receivers || []) end)
        |> Enum.reduce_while(0, fn rule, count ->
          new_receivers =
            rule.receivers
            |> Enum.map(fn r -> if r == old_str, do: new_str, else: r end)
            |> Enum.uniq()

          case Ezagent.Routing.RuleStore.update_receivers(rule.id, new_receivers, rule.enabled) do
            :ok ->
              {:cont, count + 1}

            {:error, reason} ->
              # Roll the WHOLE batch back — every row rewritten so far in
              # this transaction is atomically restored to the OLD URI.
              EzagentCore.Repo.rollback({:repoint_failed, reason})
          end
        end)
      end)

    case txn do
      {:ok, rewritten} -> {:ok, rewritten}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A `RuleStore` exception escaped the transaction fun; Ecto has
    # already rolled the transaction back. Surface a tagged error — no
    # partially-rewritten rows survive.
    e -> {:error, {:repoint_failed, e}}
  catch
    kind, reason -> {:error, {:repoint_failed, {kind, reason}}}
  end

  # The registry reload — captured: a raise (e.g.
  # `RoutingRegistry.get_meta/1` raising for an undeclared table) becomes
  # a tagged `{:error, _}` so a swap step that needs the reload can
  # abort cleanly instead of crashing.
  defp reload_registry(table) do
    Ezagent.Routing.RuleStore.load_into_registry(table)
    :ok
  rescue
    e -> {:error, {:registry_reload_failed, e}}
  catch
    _, reason -> {:error, {:registry_reload_failed, reason}}
  end

  # HIGH-1 (round 4) — the routing re-point transaction rolled back. The
  # persisted routing rows are ALREADY atomically restored to the OLD
  # worker by the transaction — there is no routing state to revert. The
  # only thing not in the SQL transaction is the working-copy slot tuple
  # (a Session-Kind slice), which step 2 committed to the NEW worker;
  # revert it to the OLD worker in one call. Then terminate the NEW
  # orphan worker and keep the OLD worker alive + still routed-to.
  #
  # Keeping the old worker alive is the least-disruptive choice: it is
  # still a valid, running agent; the slot + routing both name it as
  # before the (failed) swap — no outage, no stale route to a dead
  # process.
  defp abort_swap_after_repoint_rollback(
         slot_name,
         %URI{} = session_uri,
         old_template_uri,
         %URI{} = old_worker_uri,
         %URI{} = new_worker_uri,
         old_generation,
         %URI{} = caller,
         caps,
         reason
       ) do
    Logger.warning(
      "update_agent_template: routing re-point transaction rolled back " <>
        "(#{inspect(reason)}) for slot #{slot_name} — aborting the swap, the persisted " <>
        "routing rows are atomically back on the OLD worker " <>
        "#{URI.to_string(old_worker_uri)}, which is kept alive"
    )

    rollback_slot_to_old(
      session_uri,
      slot_name,
      old_template_uri,
      old_worker_uri,
      old_generation,
      caller,
      caps
    )

    compensate_orphan_worker(new_worker_uri, caller, caps, {:repoint_aborted, reason})
    {:error, {:update_aborted, reason}}
  end

  # Roll the swapped slot tuple back to the OLD worker. The slot tuple
  # was committed to the working copy by `upsert_agent_slot`; on a
  # re-point abort it must again name the OLD (live) worker. A legacy
  # 2-tuple slot had `old_template_uri == nil` — preserve `nil` so the
  # restored tuple stays faithful to the pre-swap state.
  defp rollback_slot_to_old(
         %URI{} = session_uri,
         slot_name,
         old_template_uri,
         %URI{} = old_worker_uri,
         old_generation,
         %URI{} = caller,
         caps
       ) do
    template_uri = old_template_uri || old_worker_uri

    case upsert_agent_slot(
           session_uri,
           slot_name,
           template_uri,
           old_worker_uri,
           old_generation,
           caller,
           caps
         ) do
      :ok ->
        :ok

      {:error, rollback_reason} ->
        Logger.error(
          "update_agent_template: rolling the slot tuple back to the OLD worker " <>
            "#{URI.to_string(old_worker_uri)} failed: #{inspect(rollback_reason)} — " <>
            "the working copy may name a terminated worker; manual review required"
        )

        :error
    end
  end

  # Terminate the OLD worker after a successful swap. HIGH-6 — the new
  # worker always has a fresh generation-specific URI, so it is never
  # the same process as the old; the URI-equality guard below is
  # belt-and-braces against a degenerate generation collision.
  defp maybe_terminate_old(%URI{} = old_worker_uri, %URI{} = new_worker_uri, caller, caps) do
    if URI.to_string(old_worker_uri) == URI.to_string(new_worker_uri) do
      :ok
    else
      case terminate_worker(old_worker_uri, caller, caps) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "update_agent_template: new worker live, but terminating old worker " <>
              "#{URI.to_string(old_worker_uri)} failed: #{inspect(reason)} — stale process left"
          )

          :ok
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
  # The orchestrator may pass a `{:mention, "x"}` tuple OR an already-
  # JSON-shaped map; both converge to the `Matcher` JSON map.
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

  `persist_version/3` spawns the SessionTemplate Kind at the
  content-hash URI and dispatches `Behavior.Template` `:write` — which
  writes a real `kind_snapshots` row. The version is content-addressed:
  identical content ⇒ identical hash ⇒ idempotent.

  ## CapBAC — HIGH-9 hardening

  The tool runs `check_template_write_cap/2` (cap #3, `:session_template`,
  `{:within_workspace, ws}`) at the boundary, AND threads the
  orchestrator's `{caller, caps}` into `persist_version/3` so the
  decisive `template.write` dispatch is CapBAC-checked against the
  ORCHESTRATOR's real authority — NOT `admin_caps`. The pre-hardening
  code called `persist_version/2`, whose `:write` ran under ambient
  admin authority; that admin fallback is removed from the tool path.

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

      # HIGH-9 — thread the orchestrator's context; NO admin fallback.
      SessionTemplate.persist_version(content, workspace_uri,
        caller: caller_uri,
        caps: caps
      )
    end
  end

  # Phase 7 PR 48 + HIGH-8 hardening — parent-template-deletion check.
  #
  # ## The HIGH-8 bug
  #
  # The pre-hardening check used ONLY `KindRegistry.lookup/1` — a
  # live-pid registry. After a phx restart (or process culling) a
  # SessionTemplate version that IS durably persisted in `kind_snapshots`
  # but not currently spawned was wrongly reported
  # `:parent_template_deleted`, so `update_template` falsely failed even
  # though the parent template still exists.
  #
  # ## The fix
  #
  # Existence is checked against the DURABLE store —
  # `Ezagent.Ecto.KindSnapshot.get/1`. A parent is "alive" iff it is
  # either live in `KindRegistry` OR has a `kind_snapshots` row (a Kind
  # that is `{:snapshot, :on_change}` snapshots on its first slice
  # write, so a persisted SessionTemplate version always has a row). A
  # genuinely-never-registered / deleted parent has NEITHER → still
  # `:parent_template_deleted`. `SpawnRegistry.spawn` is deliberately
  # NOT used to probe — it would bring up a FRESH empty Kind for any
  # URI and mask a real deletion.
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

  # True iff a `kind_snapshots` row exists for `uri` — the durable
  # existence check (HIGH-8). DB errors degrade to `false` (treated as
  # "not durably present") rather than crashing the tool.
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

  After persistence, grants the owner a `Behavior.Template`
  SessionTemplate cap on the workspace (SPEC §1.7 (e)) so the owner can
  later instantiate it via the Generator.

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

      # HIGH-9 — thread the orchestrator's context; NO admin fallback.
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
  # workspace so they may later instantiate it (the Generator's
  # owner-cap preflight, §1.4 / PR-4, checks exactly this).
  #
  # The grant dispatches `identity.grant_cap` on the owner's User Kind.
  # The grant itself runs as a system context — the WHO-may-save
  # authority was already enforced by `check_template_write_cap/2` at
  # the tool boundary.
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
        # §1.7 (e) ordering — template first, cap second.
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

  This is the one tool that is a pure read of `kind_snapshots`
  (`Ezagent.Ecto.KindSnapshot.list_in_workspace/1`), NOT a dispatch.
  CapBAC is enforced HERE, **per kind**:

  - AgentTemplate rows are included ONLY if `caps` contains a
    `Behavior.Template` cap matching `kind: :agent_template` (cap #4);
  - SessionTemplate rows are included ONLY if `caps` contains a
    `Behavior.Template` cap matching `kind: :session_template` (cap #3).

  A caller with only cap #4 sees `agent_templates: [...]` and
  `session_templates: []`; a caller with only cap #3 sees the inverse;
  a caller with neither gets `{:error, :unauthorized}`. There is NO
  cross-kind leak and NO `admin_caps` fallback.

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
    # DB unavailable / no rows — empty catalog.
    _ -> []
  end

  # Partition the snapshot rows by `kind_type`, parse the URI, apply the
  # name filter. Rows whose `kind_type` does not match are dropped.
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
  corresponding function above. Returns `{:error, {:unknown_tool, name}}`
  for non-listed names (CI gate against silently-added tools).
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

  # The dispatch ctx for every tool action — the orchestrator's URI as
  # `caller`, its delegated caps as `caps`. NEVER `admin_caps`. A missing
  # delegated cap means CapBAC denies — fail closed.
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

  # The per-kind cap check for `list_templates` / template-write tools.
  # Builds the same `needed` shape CapBAC uses (a representative
  # workspace template URI) and checks `Capability.matches?/2` — so the
  # MCP-boundary check stays structurally aligned with dispatch CapBAC.
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

  # Tool-boundary cap check for `update_template` / `save_template_as` —
  # both need cap #3 (`:session_template` `Behavior.Template`).
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

  # The durable slot tuple is the 4-tuple
  # `{slot_name, source_agent_template_uri, live_worker_uri, generation}`
  # (CRITICAL + HIGH-6 hardening). Live worker URIs are READ from the
  # slot, never re-derived from `{workspace, flavor, slot_name}` — that
  # re-derivation was collision-prone across sessions.

  # Append/replace a slot's 4-tuple in the durable
  # `template_working_copy.agent_slots` slice via `chat.set_working_copy`.
  # Stores the CURRENT live worker URI + generation so subsequent reads
  # resolve the actual running process, not a guessed URI.
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

  # Drop a slot's tuple from `agent_slots`.
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

  # Reject the tuple(s) for `slot_name`. Tolerates legacy 2-tuples /
  # 3-tuples in a pre-hardening snapshot (`normalize_slot/1` widens
  # them) — `slot_tuple_name/1` reads the name from any arity.
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

  # Find a slot's full normalized 4-tuple
  # `{slot_name, source_agent_template_uri, live_worker_uri, generation}`,
  # or `nil`. Used by `update_agent_template` to capture the OLD worker
  # URI + current generation before the swap.
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

  # Widen any stored slot tuple to the canonical 4-tuple. A pre-hardening
  # snapshot may carry a 2-tuple `{name, src}` or 3-tuple
  # `{name, src, worker}`; those have no recorded live URI, so the
  # worker URI is `nil` (callers treat that as "no live worker").
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

  # Resolve a slot's CURRENT live worker URI — READ from the durable
  # slot tuple (CRITICAL fix), never re-derived. `:no_slot` if the slot
  # is absent OR has no recorded live URI (legacy snapshot).
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
  # `session_uri` and `name` are deliberately ABSENT from the emitted
  # slice so two different sessions with an identical team config hash
  # identically.
  #
  # The durable `agent_slots` is the 4-tuple
  # `{slot_name, source_agent_template_uri, live_worker_uri, generation}`,
  # but the EMITTED template content projects to the 2-tuple
  # `{slot_name, source_agent_template_uri}` — the live worker URI +
  # generation are SESSION-SPECIFIC (CRITICAL fix) and MUST NOT enter
  # the content hash, or two sessions with the same team would hash
  # differently.
  defp build_working_copy(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = _caller_uri,
         parent_uri
       ) do
    wc = read_template_working_copy(session_uri)

    orchestrator_template_uri =
      Map.get(wc, :orchestrator_template_uri) ||
        URI.parse("template://agent/default/cc-orchestrator")

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

  # Derive a workspace URI from the orchestrator's session URI — used by
  # `update_agent_template` when building the replacement worker's
  # instance URI. The 3-segment session URI carries the workspace name
  # as its first path segment.
  defp derive_workspace(%URI{} = session_uri) do
    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = ws -> ws
      :any -> URI.new!("workspace://default")
    end
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

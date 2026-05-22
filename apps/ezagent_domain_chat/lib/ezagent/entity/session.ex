defmodule Ezagent.Entity.Session do
  @moduledoc """
  Session Kind — the "room" in Phase 2's chat routing model.

  A Session is the entity that holds a set of member URIs and routes
  outbound chat messages to them. Per Decision #61 + P2-D2 K-path:
  Session handles `:send / :join / :leave` actions; the member-side
  `:receive` action runs on the recipient Kind (User / Agent).

  Phase 2 spawns exactly one default instance — `session://default/default/main` —
  at `EzagentDomainChat.Application.start/2`. Multi-Session support is
  intentionally out of scope (Phase 3+).

  ## Persistence: {:snapshot, :on_change} — session membership survives restart

  Phase 2 originally used `:ephemeral` — members / monitors /
  last_seen were rebuilt at each boot from PubSub re-announcements
  and admin User re-join in `handle_continue(:announce_ready)`.
  Historical message stream was persisted (via `Ezagent.MessageStore`);
  only in-flight membership was ephemeral.

  **Allen V1 acceptance 2026-05-22**: adding an agent (cc_demo) to a
  session at runtime, then a phx restart, wiped it from `members`.
  Root cause — `persistence/0` was still `:ephemeral`, so the Session
  Kind's in-memory Chat slice (members map, last_seen, the
  orchestrator's working-copy) was never snapshotted; any restart lost
  every runtime mutation. ("Phase 7 PR 44/46" was supposed to flip
  this for orchestrator working-copy durability — SPEC §7-3 — but the
  flip never landed; only the moduledoc was updated to claim it had.)

  `persistence/0` is now `{:snapshot, :on_change}` — the same mode the
  `Ezagent.Entity.User` Kind already uses. After every Chat-slice
  mutation (`:send` / `:join` / `:leave` / `:DOWN`), `Ezagent.Kind.Server`
  writes the slice to `kind_snapshots`; on (re)spawn,
  `Ezagent.Kind.Snapshot.load_or_init/3` rehydrates it. Membership,
  last_seen, and the orchestrator working-copy now survive an unclean
  crash, not just a graceful shutdown.

  ### Slice serialization

  The Chat slice (`Ezagent.Behavior.Chat`) holds `members`
  (`%{URI => %{online: bool}}`), `monitors` (`%{reference => URI}`),
  and `last_seen` (`%{URI => DateTime}`). `URI` structs, `DateTime`,
  booleans, and `reference()` are all serializable via
  `:erlang.term_to_binary/1` and decode safely under the `[:safe]`
  flag — no pids, no funs, no anonymous closures. `monitors` refs are
  stale across a restart (a `reference()` is only meaningful for a
  live monitor), but that is harmless: a stale ref simply never
  matches an incoming `:DOWN`, and a member rejoin via `chat.join`
  re-monitors the live pid. `last_seen` reflects history, not live
  state. Members get re-validated when their owning Kind comes up.

  ### WorkspaceRegistry rebind (invariant 4)

  When a Session Kind rehydrates after a restart, its
  `WorkspaceRegistry` binding must be re-established so workspace-scoped
  routing rules still fire. Per Phase 9 PR-7 the workspace lives in the
  3-segment session URI (`session://<template>/<workspace>/<name>`), so
  `WorkspaceRegistry` is a consistency cache and the binding is derived
  structurally from the URI. The chat plugin's `session` spawn fn
  (`EzagentDomainChat.Application.register_spawn_fns/0`) calls
  `WorkspaceRegistry.bind/2` on every spawn — covering the lazy
  demand-spawn rehydrate path as well as `EzagentDomainChat.create_session/2`.
  """

  @behaviour Ezagent.Kind

  alias Ezagent.Routing.RuleStore

  @impl Ezagent.Kind
  def type_name, do: :session

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Chat]

  # Allen V1 acceptance 2026-05-22 — session membership + chat config
  # must survive a phx restart (even an unclean crash, hence :on_change
  # not :on_terminate). The Chat slice is fully serializable; see the
  # moduledoc "Slice serialization" section. Same persistence mode the
  # User Kind already uses.
  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): Session Kinds live under the
  # chat domain's SessionSupervisor. `Ezagent.Kind.spawn/2` reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainChat.SessionSupervisor

  @doc """
  URI of the default Session instance spawned at boot.

  SPEC v3 §3.6 (Phase 9 PR-7) — sessions are 3-segment:
  `session://<template>/<workspace>/<name>`. The default session is
  the canonical entry point and lives in `workspace://default` under
  the `default` template name.
  """
  @spec default_uri() :: URI.t()
  def default_uri, do: URI.new!("session://default/default/main")

  @doc """
  Phase 7 completion PR-4 — the **Generator**, fully (SPEC §2 PR-4).

  Per SPEC D7-2 + Allen 2026-05-18 round 2: "创建一个新 session(自带
  orchestrator)的一段程序是 generator". Not an agent — just the spawn
  program. Each new session gets its own orchestrator instance baked in
  AND the team of workers the SessionTemplate composes.

  ## The 8 phase7-SPEC steps (SPEC §2 PR-4)

  1. **Owner preflight (the Generator entry gate).** Before
     instantiating anything, load the OWNER's actual caps via
     `Ezagent.Identity.list_caps_for/1` and confirm the owner holds a
     `Ezagent.Behavior.Template` cap for `:session_template` covering
     the SessionTemplate's workspace. No authority → `{:error,
     :unauthorized}` — the owner cannot create the session. This IS
     the `template:instantiate` authority check (SPEC §2 PR-4 steps
     6+7 reconciled to one coherent gate).
  2. **Read the SessionTemplate `:template` content** — via a
     `template.read` dispatch (the `Ezagent.Behavior.Template` `:read`
     action). The content carries `agent_slots`, `routing_rules`,
     `orchestrator_template_uri`, `default_workspace_uri`.
  3. **Spawn a fresh Session** + bind its workspace.
  4. **Spawn the orchestrator** agent into the session's workspace.
  5. **Resolve `agent_slots`** — for each slot the SessionTemplate
     cites an AgentTemplate URI; instantiate the worker by dispatching
     `template.instantiate` on that AgentTemplate URI (the §1.0
     `:instantiate` action → `spawn_from_template_content/4` → records
     lineage under the orchestrator + binds workspace). NEVER
     `Class.instantiate/3` directly.
  6. **Populate `template_working_copy.agent_slots`** — record each
     `{slot_name, source_agent_template_uri}` into the new Session's
     `template_working_copy` `:chat`-slice field (PR-2).
  7. **Resolve `routing_rules`** — the SessionTemplate's rules express
     receivers as slot NAMES; resolve names → per-instance worker
     URIs → install via `Ezagent.Routing.RuleStore.add/5`.
  8. **Grant the orchestrator's scoped caps** — `grant_scoped_caps/3`
     grants caps #1 (`{:within_session}`) + #2 (`{:spawned_by}`)
     unconditionally, and caps #3 (`:session_template`) + #4
     (`:agent_template`) — each ONLY after an owner-cap preflight
     (§1.4) confirms the owner actually holds the delegated authority.

  ## Args

  - `session_template_uri` — `template://session/<workspace>/<name>@<hash>`
  - `owner_uri` — `%URI{}` of the human / principal triggering the
    instantiation. The Generator's authority IS the owner's authority
    — the owner-cap preflight (step 1) gates entry.

  ## Return

  `{:ok, %{session_uri: URI.t(), orchestrator_uri: URI.t()}}` on success,
  `{:error, reason}` on preflight denial / lookup / spawn failures.

  ## CapBAC gate

  Per SPEC §2 PR-4: the Generator entry preflights the owner's
  SessionTemplate `Behavior.Template` instantiate authority (step 1).
  A caller without that cap is denied at entry — no session, no
  orchestrator. This replaces the pre-PR-4 "Generator trusts the
  caller" comment: authority is now enforced here, not at the LV.
  """
  @spec spawn_from_template(URI.t(), URI.t()) ::
          {:ok, %{session_uri: URI.t(), orchestrator_uri: URI.t()}} | {:error, term()}
  def spawn_from_template(%URI{} = session_template_uri_in, %URI{} = owner_uri_in) do
    # Canonicalize both URIs through a parse round-trip. A `%URI{}` built
    # via `URI.new!/1` has `authority: nil` while the same string parsed
    # via `URI.parse/1` has `authority` populated — and `Capability`
    # matching is exact struct equality on the `instance` URI. Without
    # this, a Generator call whose caller built the URIs with `URI.new!`
    # would fail the owner-cap preflight against caps stored in parsed
    # form (register/lookup key parity).
    session_template_uri = URI.parse(URI.to_string(session_template_uri_in))
    owner_uri = URI.parse(URI.to_string(owner_uri_in))

    # ── MEDIUM-5 hardening: preflight EVERYTHING before any spawn ──────
    #
    # The pre-hardening Generator did irreversible side effects in a
    # `with` chain with no cleanup — a late failure (a bad routing
    # matcher, a missing AgentTemplate) left an orphaned session +
    # workers + caps. The preflight below verifies, with NO side
    # effects, every precondition that can be checked up front:
    # template aliveness, owner authority, the destination workspace
    # (HIGH-4), each agent-slot template's resolvability, and each
    # routing matcher's validity. Only then does `do_spawn/4` start
    # spawning — and `do_spawn/4` itself runs compensating cleanup if a
    # post-spawn step fails.
    with {:ok, _template_pid} <- ensure_template_alive(session_template_uri),
         :ok <- owner_instantiate_preflight(session_template_uri, owner_uri),
         {:ok, template_content} <- read_template_content(session_template_uri),
         {:ok, workspace_uri} <- resolve_target_workspace(template_content),
         :ok <-
           preflight_workspace_isolation(
             session_template_uri,
             workspace_uri,
             template_content
           ),
         :ok <- preflight_agent_slots(template_content),
         :ok <- preflight_slot_name_uniqueness(template_content),
         :ok <- preflight_routing_rules(template_content) do
      do_spawn(template_content, workspace_uri, owner_uri, session_template_uri)
    end
  end

  # --- MEDIUM-3 (round 3): slot-name uniqueness preflight --------------
  #
  # Every agent slot spawns a worker whose live instance URI is derived
  # deterministically from its generated instance name
  # (`Agent.session_instance_name/3`). Two slots that generate the SAME
  # instance name would produce the SAME worker URI — the second spawn
  # would silently re-use the first slot's worker (`{:already_started}`).
  #
  # `Ezagent.Orchestrator.SlotNames.preflight/2` computes EVERY candidate
  # instance name up front and rejects the Generator run if any two
  # collide — BEFORE a single `template.instantiate` dispatch. Every
  # Generator slot is generation 0; the session discriminator is shared
  # by all slots, so a placeholder discriminator suffices here (a
  # collision is independent of the discriminator — the suffix is
  # appended identically to every slot's name). The real per-session
  # discriminator is folded in at spawn time in `instantiate_agent_slots`.
  defp preflight_slot_name_uniqueness(template_content) do
    slot_specs =
      template_content
      |> Map.get(:agent_slots, [])
      |> normalize_agent_slots()
      |> Enum.map(fn {slot_name, _agent_template_uri} -> {slot_name, 0} end)

    Ezagent.Orchestrator.SlotNames.preflight(slot_specs, "preflight")
  end

  # --- CRITICAL (round 2): SessionTemplate-composition workspace isolation
  #
  # ## The bug
  #
  # `instantiate_one_slot/5` dispatches each agent slot's
  # `template.instantiate` with `Ezagent.Entity.User.admin_caps()` in
  # `ctx.caps`. `owner_instantiate_preflight/2` only checks the OWNER
  # against the SessionTemplate's OWN workspace — it never checks the
  # `default_workspace_uri` the Generator resolves from template content,
  # nor the workspace of each slot's AgentTemplate URI. A caller able to
  # create/instantiate a SessionTemplate in workspace A could therefore
  # encode a DIFFERENT `default_workspace_uri` and/or slot AgentTemplate
  # URIs pointing at workspace B; every slot `template.instantiate` then
  # runs as ADMIN against a B-workspace AgentTemplate → cross-workspace
  # CapBAC + isolation bypass.
  #
  # ## The fix — the same-workspace rule
  #
  # A SessionTemplate may only compose AgentTemplates in its OWN
  # workspace, and may only instantiate into its own workspace. We
  # require, structurally:
  #
  #   SessionTemplate URI workspace
  #     == resolved default_workspace_uri
  #     == every agent-slot AgentTemplate URI workspace
  #
  # Any divergence → `{:error, :cross_workspace_denied}`, nothing
  # spawned. This is chosen over a per-slot owner-cap preflight because
  # (a) V1 has no cross-workspace templating — a SessionTemplate and the
  # AgentTemplates it cites are authored together in one workspace —
  # (b) it is a single structural invariant a reviewer can verify, and
  # (c) it closes the escalation regardless of what the owner happens to
  # hold (the per-slot owner-cap check would still PASS the dispatch
  # under `admin_caps` — it only gates which caps were delegated to the
  # orchestrator, not the slot-instantiation dispatch itself). The
  # admin-cap slot dispatch is now safe because it can ONLY reach an
  # AgentTemplate proven to be in the SessionTemplate's own workspace,
  # for which the owner's authority was already established by
  # `owner_instantiate_preflight/2`.
  defp preflight_workspace_isolation(
         %URI{} = session_template_uri,
         %URI{} = workspace_uri,
         template_content
       ) do
    template_ws = Ezagent.Capability.workspace_of(session_template_uri)

    with :ok <- same_workspace(template_ws, workspace_uri, :default_workspace_uri),
         :ok <- slots_in_workspace(template_content, template_ws) do
      :ok
    end
  end

  # Compare two workspace URIs by their bare name (the `workspace://`
  # host). `workspace_of/1` may return `:any` for a malformed URI — a
  # non-`%URI{}` workspace is itself a cross-workspace denial.
  defp same_workspace(%URI{host: a}, %URI{host: b}, _which) when is_binary(a) and a == b,
    do: :ok

  defp same_workspace(_template_ws, _other_ws, which),
    do: {:error, {:cross_workspace_denied, which}}

  # Every agent-slot AgentTemplate URI must live in the SessionTemplate's
  # own workspace. A slot URI in another workspace → denial.
  defp slots_in_workspace(template_content, %URI{} = template_ws) do
    slots = normalize_agent_slots(Map.get(template_content, :agent_slots, []))

    Enum.reduce_while(slots, :ok, fn {slot_name, %URI{} = agent_template_uri}, :ok ->
      case Ezagent.Capability.workspace_of(agent_template_uri) do
        %URI{host: ws} when is_binary(ws) and ws == template_ws.host ->
          {:cont, :ok}

        other ->
          {:halt,
           {:error,
            {:cross_workspace_denied, {:agent_slot, slot_name, slot_workspace_label(other)}}}}
      end
    end)
  end

  defp slot_workspace_label(%URI{} = uri), do: URI.to_string(uri)
  defp slot_workspace_label(other), do: other

  # ── The spawn phase (MEDIUM-5) — irreversible side effects + cleanup ──
  #
  # Each step is irreversible; on failure of a LATER step,
  # `cleanup_partial/1` tears down everything spawned so far so no
  # half-built session/workers/rules/caps survive.
  defp do_spawn(
         template_content,
         %URI{} = workspace_uri,
         %URI{} = owner_uri,
         %URI{} = session_template_uri
       ) do
    with {:ok, session_uri} <- spawn_fresh_session(workspace_uri),
         # codex round-10 HIGH-1 — the session is LIVE the instant
         # `spawn_fresh_session` returns. Both the workspace bind AND
         # the orchestrator spawn are now wrapped in `guard/2` so a
         # failure of either triggers `cleanup_partial/1` (terminate +
         # unbind the session). Pre-round-10 a `bind` or
         # `spawn_orchestrator` failure returned DIRECTLY from the
         # `with` — `cleanup_partial/1` never ran — leaking a live
         # Session Kind and (for an orchestrator failure that happens
         # after the bind) its `WorkspaceRegistry` binding.
         # `cleanup_partial/1` handles a `nil` `orchestrator_uri` (the
         # orchestrator was never created in this failure path) via its
         # `if orchestrator_uri` guard.
         :ok <-
           guard(
             Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri),
             %{session_uri: session_uri, orchestrator_uri: nil, slots: []}
           ),
         {:ok, orchestrator_uri} <-
           guard(
             spawn_orchestrator(session_uri, workspace_uri, owner_uri) ||
               {:error, :orchestrator_spawn_failed},
             %{session_uri: session_uri, orchestrator_uri: nil, slots: []}
           ),
         # MEDIUM-3 (round 4) — none of this run's candidate worker URIs
         # may ALREADY be live in `KindRegistry` as orphans. The slot
         # worker URIs fold the (just-created, globally-unique) session
         # discriminator, so they are only computable now — after
         # `spawn_fresh_session`. A live candidate URI here means a stale
         # orphan from a prior failed cleanup would be silently adopted
         # by `template.instantiate`'s plugin idempotency; reject before
         # any slot spawns. Guarded so a rejection tears down the session
         # + orchestrator already spawned.
         :ok <-
           guard(
             preflight_candidate_uris_free(template_content, session_uri, workspace_uri),
             %{session_uri: session_uri, orchestrator_uri: orchestrator_uri, slots: []}
           ),
         # codex round-9 HIGH-2 — `instantiate_agent_slots/4` returns a
         # 3-element `{:error, reason, partial_slots}` when a later slot
         # fails after earlier slots already spawned. `guard/2`'s
         # 3-element clause merges `partial_slots` INTO the accumulator so
         # `cleanup_partial/1` tears down the earlier fresh workers; it
         # then returns the bare `{:error, reason}` the `with` chain
         # expects. The 2-element ok/error path is unchanged.
         {:ok, slot_instances} <-
           guard(
             instantiate_agent_slots(
               template_content,
               session_uri,
               workspace_uri,
               orchestrator_uri
             ),
             %{session_uri: session_uri, orchestrator_uri: orchestrator_uri, slots: []}
           ),
         :ok <-
           guard(
             populate_working_copy(
               session_uri,
               template_content,
               slot_instances,
               workspace_uri,
               owner_uri
             ),
             %{
               session_uri: session_uri,
               orchestrator_uri: orchestrator_uri,
               slots: slot_instances
             }
           ),
         # HIGH-3 (round 2) — `install_routing_rules/5` now returns the
         # IDs of the `routing_rules` rows it inserted; those IDs ride in
         # the `spawned` accumulator so a LATER failure's
         # `cleanup_partial/1` can DELETE exactly those rows (not just
         # reload the registry, which would re-load the dead rows).
         {:ok, routing_rule_ids} <-
           guard(
             install_routing_rules(
               template_content,
               slot_instances,
               session_uri,
               workspace_uri,
               owner_uri
             ),
             %{
               session_uri: session_uri,
               orchestrator_uri: orchestrator_uri,
               slots: slot_instances,
               routing_rule_ids: []
             }
           ),
         :ok <-
           guard(
             grant_scoped_caps(orchestrator_uri, session_uri, owner_uri),
             %{
               session_uri: session_uri,
               orchestrator_uri: orchestrator_uri,
               slots: slot_instances,
               routing_rule_ids: routing_rule_ids
             }
           ),
         :ok <-
           guard(
             register_orchestrator_mcp_context(
               orchestrator_uri,
               session_uri,
               workspace_uri,
               owner_uri,
               session_template_uri
             ),
             %{
               session_uri: session_uri,
               orchestrator_uri: orchestrator_uri,
               slots: slot_instances,
               routing_rule_ids: routing_rule_ids
             }
           ) do
      {:ok, %{session_uri: session_uri, orchestrator_uri: orchestrator_uri}}
    end
  end

  # `spawn_orchestrator/3` returns `{:ok, _}` | `{:error, _}` already,
  # so the `|| {:error, ...}` above is belt-and-braces against a nil.
  # `guard/2` runs `cleanup_partial/1` when its first arg is an error.
  #
  # codex round-9 HIGH-2 — the 3-element `{:error, reason, partial_slots}`
  # clause is for `instantiate_agent_slots/4`: a later slot failed after
  # earlier slots already spawned (`fresh?: true` — lineage recorded,
  # workspace bound, possibly a PTY sidecar started). `partial_slots` is
  # MERGED into the `spawned` accumulator's `:slots` so `cleanup_partial/1`
  # tears each earlier worker down — terminate + forget lineage + unbind
  # workspace. The bare `{:error, reason}` is then returned so the `with`
  # chain in `do_spawn/4` sees the same 2-element shape it always did.
  defp guard({:error, reason, partial_slots}, spawned) when is_list(partial_slots) do
    spawned_with_partials = Map.put(spawned, :slots, partial_slots)
    cleanup_partial(spawned_with_partials)
    {:error, reason}
  end

  defp guard({:error, reason}, spawned) do
    cleanup_partial(spawned)
    {:error, reason}
  end

  defp guard(ok, _spawned), do: ok

  # MEDIUM-5 compensating cleanup — tear down everything `do_spawn`
  # built so far. Best-effort: every step is wrapped so one failure
  # does not prevent the rest. Order: workers, then orchestrator, then
  # the session Kind, then its workspace binding.
  #
  # ## codex round-9 HIGH-2 — every spawned worker is torn down COMPLETELY
  #
  # The `slots` list now reflects REALITY: when a multi-slot template's
  # later slot fails, `instantiate_agent_slots/4` returns the earlier
  # slots created so far and `guard/2` merges them into `spawned`. Each
  # accumulated slot worker — AND the orchestrator, itself a worker the
  # Generator spawned — is terminated, has its `AgentLineage` record
  # forgotten (`terminate_kind/1`), AND has its `WorkspaceRegistry`
  # binding removed — so a failed multi-slot Generator run leaves NO
  # live worker, NO stale lineage, NO stale binding.
  #
  # ## HIGH-3 (round 2) — DELETE the COMMITTED routing rows on a
  # ## later-step failure
  #
  # `install_routing_rules/5` commits its routing rows in one
  # transaction (HIGH-2 round 4); on the committed path it returns the
  # row IDs, which ride in the `spawned` accumulator. If a LATER step
  # (`grant_scoped_caps` / `register_orchestrator_mcp_context`) then
  # fails, those committed rows must be torn down: cleanup DELETEs those
  # exact rows BEFORE `load_into_registry/1`, so the reload sees them
  # gone and they leave ETS too. (When the routing install itself fails,
  # its transaction has already rolled back — `routing_rule_ids` is `[]`
  # and there is nothing here to delete.)
  defp cleanup_partial(spawned) do
    session_uri = Map.get(spawned, :session_uri)
    orchestrator_uri = Map.get(spawned, :orchestrator_uri)
    slots = Map.get(spawned, :slots, [])
    routing_rule_ids = Map.get(spawned, :routing_rule_ids, [])

    # codex round-9 HIGH-2 — each accumulated slot worker is torn down
    # COMPLETELY: `terminate_kind/1` stops the process AND forgets its
    # `AgentLineage` record; `WorkspaceRegistry.unbind/1` removes its
    # workspace binding. A `fresh?: true` slot recorded all three at
    # spawn (lineage + binding + the live process), so a failed
    # multi-slot Generator run must undo all three — leaving NO live
    # worker, NO stale lineage, NO stale binding.
    Enum.each(slots, fn
      {_slot, _tmpl, %URI{} = worker_uri} ->
        terminate_kind(worker_uri)
        safe(fn -> Ezagent.WorkspaceRegistry.unbind(worker_uri) end)

      _ ->
        :ok
    end)

    # codex round-9 HIGH-2 — the orchestrator is itself a worker the
    # Generator spawned (`spawn_orchestrator/3` → `Agent.spawn/4`, which
    # binds its workspace). A failed run must leave it with NO live
    # process, NO stale lineage (`terminate_kind/1`), AND NO stale
    # `WorkspaceRegistry` binding — same three-part teardown as the slot
    # workers above.
    if orchestrator_uri do
      terminate_kind(orchestrator_uri)
      safe(fn -> Ezagent.WorkspaceRegistry.unbind(orchestrator_uri) end)
    end

    if session_uri, do: terminate_kind(session_uri)
    if session_uri, do: Ezagent.WorkspaceRegistry.unbind(session_uri)

    # HIGH-3 — delete the exact routing rows this Generator run inserted.
    Enum.each(routing_rule_ids, fn id ->
      safe(fn -> RuleStore.delete(id, force: true) end)
    end)

    # Re-hydrate the routing registry — now that the partially-installed
    # rows are gone from SQLite, the reload drops them from ETS too.
    safe(fn -> RuleStore.load_into_registry(EzagentDomainChat.Routing.MentionRouting) end)
    :ok
  end

  # Terminate a Kind process (best-effort) and forget its lineage. The
  # process is an Agent (worker / orchestrator) under `AgentSupervisor`
  # or a Session under `SessionSupervisor`; we try both — a
  # `terminate_child` against the wrong supervisor returns
  # `{:error, :not_found}` harmlessly.
  defp terminate_kind(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} ->
        Enum.each(
          [EzagentDomainChat.AgentSupervisor, EzagentDomainChat.SessionSupervisor],
          fn sup -> safe(fn -> DynamicSupervisor.terminate_child(sup, pid) end) end
        )

      :error ->
        :ok
    end

    safe(fn -> Ezagent.AgentLineage.forget(uri) end)
    :ok
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp ensure_template_alive(%URI{} = template_uri) do
    case Ezagent.KindRegistry.lookup(template_uri) do
      {:ok, pid} -> {:ok, pid}
      :error -> Ezagent.SpawnRegistry.spawn(template_uri)
    end
  end

  # --- Step 1: owner-instantiate preflight -------------------------------

  # The Generator entry gate (SPEC §2 PR-4 steps 6+7, reconciled).
  #
  # Before instantiating anything, confirm the OWNER actually holds the
  # authority to instantiate this SessionTemplate. The check is a REAL
  # match against the owner's actual caps — loaded via
  # `Ezagent.Identity.list_caps_for/1` (NOT `admin_caps()`). The owner
  # passes iff at least one of their real caps authorizes a
  # `Ezagent.Behavior.Template` action on `:session_template` in the
  # SessionTemplate's workspace (a `:any` admin cap, a
  # `{:within_workspace, ws}` template cap, or a broader template cap
  # all pass; an owner with no template authority is denied).
  #
  # This IS the `template:instantiate` authority gate — without it the
  # owner cannot create the session at all (`{:error, :unauthorized}`).
  defp owner_instantiate_preflight(%URI{} = session_template_uri, %URI{} = owner_uri) do
    owner_caps = Ezagent.Identity.list_caps_for(owner_uri)

    needed = %{
      kind: :session_template,
      behavior: Ezagent.Behavior.Template,
      instance: session_template_uri,
      workspace_uri: Ezagent.Capability.workspace_of(session_template_uri)
    }

    if Enum.any?(owner_caps, &Ezagent.Capability.matches?(&1, needed)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  # --- Step 2: read the SessionTemplate content --------------------------

  # Read the SessionTemplate's `:template` slice via the
  # `Ezagent.Behavior.Template` `:read` action — the dispatch path so
  # the read is audited. The Generator runs as a privileged bootstrap
  # program (consistent with `grant_scoped_caps/3`'s privileged grant
  # context); the WHO-may-instantiate gate is the owner preflight above.
  defp read_template_content(%URI{} = session_template_uri) do
    target = URI.parse("#{URI.to_string(session_template_uri)}?action=template.read")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{content: content}} when is_map(content) -> {:ok, content}
      {:ok, %{content: nil}} -> {:error, :session_template_not_populated}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_template_read_result, other}}
    end
  end

  # --- HIGH-4: honor the SessionTemplate's default_workspace_uri --------

  # The pre-hardening Generator IGNORED `template_content.default_workspace_uri`
  # and always created the session in `WorkspaceRegistry.default_workspace_uri/0`.
  # A non-default-workspace SessionTemplate spawned into the WRONG
  # workspace. `resolve_target_workspace/1` reads the field, validates
  # it, and that workspace is then threaded through the session URI,
  # orchestrator spawn, worker instantiation, routing install, and the
  # delegated caps.
  #
  # A `nil` / absent field falls back to `WorkspaceRegistry`'s default
  # — the common case is unchanged. A present-but-malformed value is a
  # hard error (let-it-crash — no silent fallback past a real value).
  defp resolve_target_workspace(template_content) do
    case Map.get(template_content, :default_workspace_uri) ||
           Map.get(template_content, "default_workspace_uri") do
      nil ->
        Ezagent.WorkspaceRegistry.default_workspace_uri()

      %URI{scheme: "workspace", host: host} = uri when is_binary(host) ->
        validate_workspace_name(host, uri)

      uri_str when is_binary(uri_str) ->
        case URI.parse(uri_str) do
          %URI{scheme: "workspace", host: host} = uri when is_binary(host) ->
            validate_workspace_name(host, uri)

          _ ->
            {:error, {:invalid_default_workspace_uri, uri_str}}
        end

      other ->
        {:error, {:invalid_default_workspace_uri, other}}
    end
  end

  # Invariant 11 — a workspace name must match `^[a-z][a-z0-9_-]*$`.
  defp validate_workspace_name(host, %URI{} = uri) do
    if Regex.match?(~r/^[a-z][a-z0-9_-]*$/, host) do
      {:ok, uri}
    else
      {:error, {:invalid_workspace_name, host}}
    end
  end

  # --- MEDIUM-5: agent-slot + routing preflight (no side effects) ------

  # Every agent slot's AgentTemplate must be resolvable (the Kind can be
  # brought up + has a populated `:template` slice). Bringing the
  # Template Kind up is the lazy demand-spawn — it is idempotent and not
  # a session side effect. A bad slot fails the WHOLE Generator BEFORE
  # any session/worker is spawned.
  defp preflight_agent_slots(template_content) do
    slots = normalize_agent_slots(Map.get(template_content, :agent_slots, []))

    Enum.reduce_while(slots, :ok, fn {slot_name, agent_template_uri}, :ok ->
      case ensure_template_alive(agent_template_uri) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, {:already_started, _pid}} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:agent_slot_template_unresolvable, slot_name, reason}}}
      end
    end)
  end

  # Every routing-rule matcher must be a valid matcher AST. A matcher
  # that does not round-trip through `Matcher.to_json/1` would fail at
  # `RuleStore.add/5` AFTER the session is half-built — catch it here.
  defp preflight_routing_rules(template_content) do
    rules = normalize_routing_rules(Map.get(template_content, :routing_rules, []))

    Enum.reduce_while(rules, :ok, fn {matcher_ast, _receivers}, :ok ->
      try do
        _ = Ezagent.Routing.Matcher.to_json(matcher_ast)
        {:cont, :ok}
      rescue
        _ -> {:halt, {:error, {:invalid_routing_matcher, matcher_ast}}}
      end
    end)
  end

  # SPEC v3 §3.6 (Phase 9 PR-7) — sessions are 3-segment:
  # `session://<template>/<workspace>/<name>`. HIGH-4 — the session URI
  # is built in the TARGET workspace (from the SessionTemplate's
  # `default_workspace_uri`), not always `default`.
  defp spawn_fresh_session(%URI{host: workspace_name}) when is_binary(workspace_name) do
    unique_suffix = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    session_uri = URI.new!("session://generic/#{workspace_name}/gen-#{unique_suffix}")

    case Ezagent.SpawnRegistry.spawn(session_uri) do
      {:ok, _pid} -> {:ok, session_uri}
      err -> err
    end
  end

  defp spawn_orchestrator(session_uri, workspace_uri, owner_uri) do
    # Spawn the cc-orchestrator (PR 45 seed) under a fresh instance
    # name keyed to this session for traceability. SPEC v3 §3.6 PR-7
    # — the orchestrator AgentTemplate is workspace-scoped to `default`
    # (a shared seed); the orchestrator INSTANCE is spawned into the
    # session's own (HIGH-4-resolved) workspace via `workspace_uri`.
    template_uri = URI.parse("template://agent/default/cc-orchestrator")
    # session_uri.path = "/<workspace>/<name>" → use name as suffix
    session_name =
      case session_uri.path do
        "/" <> rest ->
          case String.split(rest, "/", parts: 2) do
            [_ws, name] -> name
            _ -> session_uri.host
          end

        _ ->
          session_uri.host
      end

    # SPEC §1.2 — agent instance URIs are `entity://agent/<ws>/<flavor>_<name>`.
    # The orchestrator is a `cc`-flavored agent (the seed
    # `cc-orchestrator` AgentTemplate has `flavor: "cc"`), so the
    # instance name MUST carry the `cc_` flavor prefix — without it the
    # chat plugin's agent-spawn resolver cannot map the URI to a
    # `kind_module` (`{:error, :no_kind_module_for_agent}`).
    instance_name = "cc_orchestrator-#{session_name}"

    Ezagent.Entity.Agent.spawn(template_uri, instance_name, workspace_uri, owner_uri)
  end

  # --- MEDIUM-3 (round 4): candidate-worker-URI orphan preflight -------

  # Compute every slot's FULL candidate worker URI
  # (`entity://agent/<workspace>/<flavor>_<instance_name>` at generation
  # 0, with this run's session discriminator) and reject the Generator
  # run if any is ALREADY live in `KindRegistry` — a stale orphan a prior
  # failed cleanup left behind, which `template.instantiate`'s plugin
  # idempotency would otherwise silently adopt.
  #
  # No candidate has a legitimate live worker yet (this is a fresh
  # session), so `expected_uri` is `nil` for every candidate. A slot
  # whose AgentTemplate has no flavor is skipped here — `instantiate_one_slot`
  # surfaces the flavor error.
  defp preflight_candidate_uris_free(template_content, %URI{} = session_uri, %URI{} = workspace_uri) do
    slots = normalize_agent_slots(Map.get(template_content, :agent_slots, []))
    discriminator = session_discriminator(session_uri)
    workspace_name = workspace_uri.host || "default"

    candidates =
      Enum.flat_map(slots, fn {slot_name, %URI{} = agent_template_uri} ->
        instance_name = Ezagent.Entity.Agent.session_instance_name(slot_name, discriminator)

        case agent_template_flavor(agent_template_uri) do
          {:ok, flavor} ->
            uri = URI.new!("entity://agent/#{workspace_name}/#{flavor}_#{instance_name}")
            [{uri, nil}]

          :no_flavor ->
            []
        end
      end)

    Ezagent.Orchestrator.SlotNames.preflight_live_worker_uris(candidates)
  end

  # Read an AgentTemplate's `flavor` from its `:template` slice content
  # via the `template.read` dispatch (the AgentTemplate Kind is already
  # alive — `preflight_agent_slots` ensured it). Returns `:no_flavor`
  # when the content has no flavor or the read fails (the candidate URI
  # is then underivable; `instantiate_one_slot` will surface the error).
  defp agent_template_flavor(%URI{} = agent_template_uri) do
    target = URI.parse("#{URI.to_string(agent_template_uri)}?action=template.read")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{content: content}} when is_map(content) ->
        case Map.get(content, :flavor) || Map.get(content, "flavor") do
          flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
          _ -> :no_flavor
        end

      _ ->
        :no_flavor
    end
  end

  # --- Step 5: resolve + instantiate agent_slots -------------------------

  # For each slot the SessionTemplate cites an AgentTemplate URI.
  # Instantiate the worker by dispatching `template.instantiate` on that
  # AgentTemplate URI — the `Ezagent.Behavior.Template` `:instantiate`
  # action (§1.0). That action resolves the flavor Class and hands off to
  # `Ezagent.Entity.Agent.spawn_from_template_content/4` (§1.6a), which
  # delegates the launch + records lineage UNDER THE ORCHESTRATOR + binds
  # the workspace. The Generator NEVER calls `Class.instantiate/3`
  # directly and NEVER re-implements lineage/binding.
  #
  # `spawned_by: orchestrator_uri` is passed so each worker lands in the
  # orchestrator's `AgentLineage` — cap #2 (`{:spawned_by, orchestrator}`)
  # then resolves for the orchestrator's own workers.
  #
  # CRITICAL hardening fix — the LIVE worker `instance_name` is made
  # **session-unique** via `Ezagent.Entity.Agent.session_instance_name/3`
  # (the session URI's name segment is the discriminator). Two sessions
  # from the SAME SessionTemplate therefore get DISJOINT live worker
  # URIs, so neither overwrites the other's `AgentLineage` row.
  #
  # Returns `{:ok, [{slot_name, agent_template_uri, worker_uri}]}` — the
  # working copy + the routing rules both consume this list. The
  # `worker_uri` here is the durable record of the LIVE instance URI.
  #
  # ## codex round-9 HIGH-2 — return the PARTIAL slots on a slot failure
  #
  # Slots are instantiated SEQUENTIALLY: slot 1 may be `fresh?: true`
  # (records lineage, binds the workspace, may start a PTY sidecar)
  # before slot 2 fails. The pre-round-9 error path returned a bare
  # `{:error, reason}` — the slots created so far were LOST, so
  # `do_spawn/4`'s `guard/2` accumulator carried `slots: []` and
  # `cleanup_partial/1` left slot 1's worker live, workspace-bound, and
  # lineaged to a now-terminated orchestrator. A rejected slot was NOT
  # zero-side-effect at the Generator level.
  #
  # On a slot failure this now returns the 3-element
  # `{:error, reason, partial_slots}` — the slots created BEFORE the
  # failure, in `{slot_name, agent_template_uri, worker_uri}` shape.
  # `do_spawn/4` threads `partial_slots` into the `guard/2` accumulator
  # so `cleanup_partial/1` tears each one down.
  defp instantiate_agent_slots(
         template_content,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = orchestrator_uri
       ) do
    slots = normalize_agent_slots(Map.get(template_content, :agent_slots, []))
    discriminator = session_discriminator(session_uri)

    Enum.reduce_while(slots, {:ok, []}, fn {slot_name, agent_template_uri}, {:ok, acc} ->
      case instantiate_one_slot(
             slot_name,
             agent_template_uri,
             discriminator,
             workspace_uri,
             orchestrator_uri
           ) do
        {:ok, worker_uri} ->
          {:cont, {:ok, [{slot_name, agent_template_uri, worker_uri} | acc]}}

        {:error, reason} ->
          # Carry the slots created BEFORE this failure (the reduce
          # accumulator) into the error so `do_spawn/4` can clean them up.
          {:halt, {:error, {:agent_slot_failed, slot_name, reason}, Enum.reverse(acc)}}
      end
    end)
    |> case do
      {:ok, instances} -> {:ok, Enum.reverse(instances)}
      {:error, _reason, _partial} = err -> err
    end
  end

  # The session-scoped discriminator folded into every LIVE worker
  # instance name (CRITICAL fix) — the session URI's name segment,
  # which `spawn_fresh_session/0` already makes globally unique
  # (`gen-<millis>-<unique_int>`).
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

  # Instantiate ONE slot: dispatch `template.instantiate` on its
  # AgentTemplate URI. `instance_name` is the SESSION-UNIQUE live
  # instance name (CRITICAL fix round 1) — `session_instance_name/3`
  # folds the session discriminator into the slot name so the
  # `:instantiate` action builds a per-session flavor-prefixed worker
  # URI.
  #
  # ## The `admin_caps` ctx is bounded (CRITICAL round 2)
  #
  # The dispatch ctx carries `admin_caps` so the Generator (a privileged
  # bootstrap program) can instantiate the slot. This is SAFE here ONLY
  # because `preflight_workspace_isolation/3` has already proven that
  # `agent_template_uri` lives in the SAME workspace as the
  # SessionTemplate — and `owner_instantiate_preflight/2` already
  # established the owner holds `Behavior.Template` authority for THAT
  # workspace. The admin-cap dispatch therefore cannot reach an
  # AgentTemplate in a workspace the owner lacks authority over: the
  # owner-authority preflight for this exact AgentTemplate's workspace
  # has passed (transitively, via the same-workspace invariant). Without
  # `preflight_workspace_isolation/3` this would be a cross-workspace
  # escalation — see its moduledoc.
  defp instantiate_one_slot(
         slot_name,
         %URI{} = agent_template_uri,
         discriminator,
         workspace_uri,
         orchestrator_uri
       ) do
    instance_name = Ezagent.Entity.Agent.session_instance_name(slot_name, discriminator)

    with {:ok, _pid} <- ensure_template_alive(agent_template_uri),
         target <-
           URI.parse("#{URI.to_string(agent_template_uri)}?action=template.instantiate"),
         {:ok, %{workers: workers, fresh?: fresh?}} <-
           Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: %{
               instance_name: instance_name,
               workspace_uri: workspace_uri,
               spawned_by: orchestrator_uri
             },
             ctx: %{
               caller: orchestrator_uri,
               caps: Ezagent.Entity.User.admin_caps(),
               reply: {:caller_inbox, self()}
             }
           }) do
      # codex round-8 HIGH-2 — the Generator MUST gate a `fresh?: false`
      # worker on ownership verification before committing it.
      #
      # Round 7 made `spawn_from_template_content/4` record lineage +
      # bind workspace ONLY for `fresh?: true` workers. A `fresh?: false`
      # result therefore means NO lineage/workspace binding happened on
      # THIS call. The Generator used to record the worker into the
      # session working-copy + routing rules regardless of `fresh?` —
      # so a candidate worker that appeared AFTER
      # `preflight_candidate_uris_free/3` but BEFORE the atomic spawn
      # (a TOCTOU window) was silently adopted into the session with
      # UNKNOWN lineage + workspace — a worker the Generator neither
      # created nor bound.
      #
      # The legitimate idempotent re-run still exists: `Workspace.Loader`
      # re-runs the Generator on every boot pass; a re-instantiation of
      # a worker THIS orchestrator + workspace already created + bound
      # also reports `fresh?: false`. That re-run is fine — the worker
      # IS owned. So a `fresh?: false` worker is committed ONLY IF
      # ownership verifies: `AgentLineage.lookup` equals THIS
      # orchestrator AND `WorkspaceRegistry.lookup` equals the target
      # workspace. If it does not verify, the slot fails
      # `:slot_candidate_not_owned` — the Generator does NOT silently
      # adopt a foreign / unknown-lineage worker into the session.
      with {:ok, worker_uri} <- first_worker(workers),
           :ok <-
             verify_slot_candidate_ownership(
               fresh?,
               slot_name,
               worker_uri,
               workspace_uri,
               orchestrator_uri
             ) do
        {:ok, worker_uri}
      end
    else
      {:error, _} = err -> err
      other -> {:error, {:unexpected_instantiate_result, other}}
    end
  end

  defp first_worker([worker_uri | _]), do: {:ok, worker_uri}
  defp first_worker([]), do: {:error, :instantiate_returned_no_worker}

  # codex round-8 HIGH-2 — ownership verification for a `fresh?: false`
  # slot candidate.
  #
  # A `fresh?: true` worker was just created AND bound by THIS call's
  # `spawn_from_template_content/4` (round 7 gating) — it is owned by
  # construction, no check needed.
  #
  # A `fresh?: false` worker was NOT bound by this call. It is committed
  # to the session only if it is already owned by THIS orchestrator +
  # workspace — the legitimate idempotent `Workspace.Loader` re-run. The
  # ownership predicate is structural: `AgentLineage.lookup(worker_uri)`
  # must equal `orchestrator_uri` AND `WorkspaceRegistry.lookup(worker_uri)`
  # must equal `workspace_uri`. A worker that appeared in the TOCTOU
  # window (foreign / unknown lineage, or bound to a different
  # workspace, or unbound entirely) fails the check — the Generator
  # fails the slot rather than adopting it.
  #
  # URIs are compared by canonical string form: the registries store +
  # return string-derived `%URI{}` values, while `orchestrator_uri` /
  # `workspace_uri` are caller-supplied structs — `URI.to_string/1`
  # normalizes both sides.
  defp verify_slot_candidate_ownership(true, _slot_name, _worker_uri, _workspace_uri, _orch_uri),
    do: :ok

  defp verify_slot_candidate_ownership(
         false,
         slot_name,
         %URI{} = worker_uri,
         %URI{} = workspace_uri,
         %URI{} = orchestrator_uri
       ) do
    lineage_ok? =
      case Ezagent.AgentLineage.lookup(worker_uri) do
        {:ok, %URI{} = spawned_by} ->
          URI.to_string(spawned_by) == URI.to_string(orchestrator_uri)

        :error ->
          false
      end

    workspace_ok? =
      case Ezagent.WorkspaceRegistry.lookup(worker_uri) do
        {:ok, %URI{} = bound_ws} ->
          URI.to_string(bound_ws) == URI.to_string(workspace_uri)

        :error ->
          false
      end

    if lineage_ok? and workspace_ok? do
      :ok
    else
      {:error, {:slot_candidate_not_owned, slot_name, URI.to_string(worker_uri)}}
    end
  end

  # `agent_slots` in the SessionTemplate content is
  # `[{slot_name, agent_template_uri}]`. After a JSON snapshot round-trip
  # the URI may be a plain string and the tuple a 2-element list —
  # normalize both back to `{String.t(), %URI{}}`.
  defp normalize_agent_slots(slots) when is_list(slots) do
    Enum.map(slots, fn
      {slot_name, %URI{} = uri} -> {to_string(slot_name), uri}
      {slot_name, uri} when is_binary(uri) -> {to_string(slot_name), URI.parse(uri)}
      [slot_name, %URI{} = uri] -> {to_string(slot_name), uri}
      [slot_name, uri] when is_binary(uri) -> {to_string(slot_name), URI.parse(uri)}
    end)
  end

  defp normalize_agent_slots(_), do: []

  # --- Step 6: populate template_working_copy ----------------------------

  # Record the durable `template_working_copy` field on the new Session's
  # `:chat` slice (PR-2's field). `agent_slots` carries the 4-tuple
  # `{slot_name, source_agent_template_uri, live_worker_uri, generation}`:
  #
  # - `slot_name` — the stable template-shaped SLOT key.
  # - `source_agent_template_uri` — the AgentTemplate URI the slot was
  #   spawned from (the durable source — survives a worker respawn).
  # - `live_worker_uri` — the CURRENT live `entity://agent/...` instance
  #   URI (CRITICAL fix). It is session-unique; storing it means
  #   `resolve_slot_worker_uri` reads the truth instead of re-deriving a
  #   collision-prone URI from `{workspace, flavor, slot_name}`.
  # - `generation` — the swap counter (HIGH-6); 0 at Generator init,
  #   incremented by each `update_agent_template`.
  #
  # `routing_rules` carries `{matcher_ast, [slot_name]}` — receivers as
  # slot NAMES. Both come straight from the SessionTemplate content.
  #
  # Written via the `chat.set_working_copy` dispatch with the
  # Generator's system-internal write path (the orchestrator-only cap
  # gate, HIGH-2, does not apply to the Generator's bootstrap init
  # write) — Session is `{:snapshot, :on_change}`, so the field survives
  # a Session restart.
  defp populate_working_copy(
         %URI{} = session_uri,
         template_content,
         slot_instances,
         %URI{} = workspace_uri,
         %URI{} = _owner_uri
       ) do
    agent_slots =
      Enum.map(slot_instances, fn {slot_name, agent_template_uri, worker_uri} ->
        {slot_name, agent_template_uri, worker_uri, 0}
      end)

    working_copy = %{
      agent_slots: agent_slots,
      routing_rules: normalize_routing_rules(Map.get(template_content, :routing_rules, [])),
      orchestrator_template_uri:
        Map.get(template_content, :orchestrator_template_uri) ||
          URI.parse("template://agent/default/cc-orchestrator"),
      default_workspace_uri: Map.get(template_content, :default_workspace_uri) || workspace_uri,
      description: Map.get(template_content, :description, "")
    }

    case Ezagent.Behavior.Chat.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  # `routing_rules` content shape `[{matcher_ast, [slot_name]}]` — after a
  # JSON snapshot round-trip the tuple may be a 2-element list; normalize.
  defp normalize_routing_rules(rules) when is_list(rules) do
    Enum.map(rules, fn
      {matcher_ast, receivers} when is_list(receivers) -> {matcher_ast, receivers}
      [matcher_ast, receivers] when is_list(receivers) -> {matcher_ast, receivers}
    end)
  end

  defp normalize_routing_rules(_), do: []

  # --- Step 7: install routing rules -------------------------------------

  # The SessionTemplate's `routing_rules` express receivers as slot
  # NAMES. Resolve each name to the per-instance worker URI just spawned
  # (step 5) and install the rule via `Ezagent.Routing.RuleStore.add/5`,
  # scoped to the workspace passed by the Generator so workspace-scoped
  # rules fire (invariant 4). Receivers a slot name doesn't resolve to
  # are skipped — a rule whose every receiver is unknown is dropped.
  #
  # ## HIGH-3 hardening (round 1) — load the rules into the live registry
  #
  # `RuleStore.add/5` only inserts the SQLite row. The live resolver
  # (`Ezagent.Routing.Resolver`) reads `RoutingRegistry` ETS, which is
  # hydrated by `RuleStore.load_into_registry/1`. After committing the
  # rows this step calls `load_into_registry/1` ONCE so every
  # Generator-installed rule is live the instant the Generator returns.
  #
  # ## HIGH-2 hardening (round 4) — the insert batch is ONE transaction
  #
  # The whole `RuleStore.add/5` loop runs inside a single
  # `EzagentCore.Repo.transaction/1` (`RuleStore` is `EzagentCore.Repo`-
  # backed). On ANY failure mid-batch — a tagged `{:error, _}` from
  # `RuleStore.add/5` OR an exception from any insert — `Repo.rollback/1`
  # is called, so EVERY row this batch inserted is atomically undone by
  # the DB. There is no partial routing state to compensate for: the
  # matcher-based `scrub_routing_rows_for` (which deleted EVERY row
  # sharing a batch matcher, regardless of workspace / created_by / id —
  # a data-loss bug that could hard-delete OTHER sessions' rules) is
  # GONE. `load_into_registry/1` runs ONLY after the transaction commits,
  # so ETS only ever reflects committed rows; if the transaction rolled
  # back there is nothing to load. `install_routing_rules/5` is therefore
  # TOTAL — `{:ok, [rule_id]} | {:error, _}`, never raises after a
  # commit — and `guard/2` always runs `cleanup_partial/1` on failure.
  #
  # On the COMMITTED path it returns `{:ok, [rule_id]}` — the IDs of the
  # `routing_rules` rows the (now-durable) batch inserted. `do_spawn/4`
  # threads them into the `spawned` accumulator so a LATER step's failure
  # (`grant_scoped_caps` / `register_orchestrator_mcp_context`) has
  # `cleanup_partial/1` DELETE exactly those committed rows.
  defp install_routing_rules(
         template_content,
         slot_instances,
         %URI{} = _session_uri,
         %URI{} = workspace_uri,
         %URI{} = owner_uri
       ) do
    rules = normalize_routing_rules(Map.get(template_content, :routing_rules, []))

    slot_uri_by_name =
      Map.new(slot_instances, fn {slot_name, _tmpl, worker_uri} -> {slot_name, worker_uri} end)

    table = EzagentDomainChat.Routing.MentionRouting

    case insert_routing_rules_txn(rules, slot_uri_by_name, table, workspace_uri, owner_uri) do
      {:ok, []} ->
        # No rules committed — nothing to reload.
        {:ok, []}

      {:ok, inserted_ids} ->
        # HIGH-3 — hydrate the live RoutingRegistry ETS so the rules fire
        # at runtime immediately. This runs ONLY after the transaction
        # committed, so ETS reflects exactly the committed rows. A raise
        # here (an undeclared routing table) is captured as a tagged
        # error; because the rows are already COMMITTED and `guard/2`
        # would receive `routing_rule_ids: []` for the failed step, we
        # delete the committed rows HERE before returning the error — the
        # registry was never loaded, so ETS stays clean and the DB is
        # restored to its pre-batch state. `install_routing_rules/5`
        # stays total.
        case safe_load_registry(table) do
          :ok ->
            {:ok, inserted_ids}

          {:error, reason} ->
            Enum.each(inserted_ids, fn id ->
              safe(fn -> RuleStore.delete(id, force: true) end)
            end)

            {:error, {:routing_install_raised, reason}}
        end

      {:error, _} = err ->
        # The transaction rolled back — ZERO rows from this batch
        # persisted, so there is nothing to delete and nothing to
        # reload. The live registry was never touched.
        err
    end
  end

  # HIGH-2 (round 4) — run the whole `RuleStore.add/5` batch inside ONE
  # `Repo.transaction`. Any mid-batch failure (tagged error OR exception)
  # calls `Repo.rollback/1`, atomically undoing every insert this batch
  # made. Returns `{:ok, [rule_id]}` (committed) or `{:error, reason}`
  # (rolled back — DB untouched). Never leaves partial routing rows.
  defp insert_routing_rules_txn(rules, slot_uri_by_name, table, workspace_uri, owner_uri) do
    txn =
      EzagentCore.Repo.transaction(fn ->
        result =
          Enum.reduce_while(rules, [], fn {matcher_ast, receiver_slot_names}, ids ->
            receiver_uris =
              receiver_slot_names
              |> Enum.map(&Map.get(slot_uri_by_name, to_string(&1)))
              |> Enum.reject(&is_nil/1)

            cond do
              receiver_uris == [] ->
                # No resolvable receiver — drop the rule (slot names that
                # don't map to a spawned worker can't route anywhere).
                {:cont, ids}

              true ->
                case RuleStore.add(
                       table,
                       matcher_ast,
                       receiver_uris,
                       owner_uri,
                       workspace_uri: workspace_uri
                     ) do
                  {:ok, %{id: id}} ->
                    {:cont, [id | ids]}

                  {:error, reason} ->
                    # Roll the WHOLE batch back — every row inserted so
                    # far in this transaction is atomically undone.
                    EzagentCore.Repo.rollback({:routing_rule_failed, reason})
                end
            end
          end)

        Enum.reverse(result)
      end)

    case txn do
      {:ok, ids} -> {:ok, ids}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A `RuleStore.add/5` exception (a DB error) escapes the transaction
    # fun; Ecto has already rolled the transaction back. Surface a tagged
    # error — no partial rows survive.
    e -> {:error, {:routing_install_raised, e}}
  catch
    kind, reason -> {:error, {:routing_install_raised, {kind, reason}}}
  end

  # Reload the routing registry, capturing a raise as a tagged error so
  # the registry-reload step of `install_routing_rules/5` stays total.
  defp safe_load_registry(table) do
    RuleStore.load_into_registry(table)
    :ok
  rescue
    e -> {:error, {:registry_reload_failed, e}}
  catch
    kind, reason -> {:error, {:registry_reload_failed, {kind, reason}}}
  end

  # Phase 7 PR 47 + completion PR-4 (step 8) — scope-bounded delegation
  # per SPEC D7-3 + §1.4.
  #
  # After the orchestrator agent spawns, grant it FOUR caps:
  #
  # 1. `{kind: :session, behavior: :any, instance: {:within_session, S}}`
  #    — orchestrator can dispatch on any URI inside its session S, but
  #    nothing outside S. UNCONDITIONAL (structural to any orchestrator).
  # 2. `{kind: :agent, behavior: :any, instance: {:spawned_by, orch}}`
  #    — orchestrator can dispatch on agents it spawned (lineage recorded
  #    by `spawn_from_template_content/4`), not on agents spawned by
  #    others. UNCONDITIONAL.
  # 3. `{kind: :session_template, behavior: Ezagent.Behavior.Template,
  #    instance: {:within_workspace, ws}}` — read/write/instantiate
  #    SessionTemplates in the orchestrator's workspace (the template
  #    tools `update_template`/`save_template_as`/`list_templates`).
  # 4. `{kind: :agent_template, behavior: Ezagent.Behavior.Template,
  #    instance: {:within_workspace, ws}}` — read/instantiate
  #    AgentTemplates in the orchestrator's workspace (`add_agent_slot`/
  #    `list_templates`-agent-rows).
  #
  # Caps #3/#4 are delegated ONLY AFTER an owner-cap preflight (§1.4):
  # the owner's ACTUAL caps (loaded via `Ezagent.Identity.list_caps_for/1`
  # — NOT `admin_caps()`) must already authorize that delegated
  # `{:within_workspace, ws}` `Behavior.Template` scope. A failing
  # preflight skips ONLY that cap (fail closed — the orchestrator just
  # can't use that tool). The Generator never fabricates authority the
  # owner lacks. Caps #1/#2 stay unconditional — they are not template
  # authority.
  #
  # The grant dispatch itself still runs as a privileged system context
  # (the Generator is a bootstrap program). The preflight — NOT the
  # grant's `ctx.caps` — is what enforces "no authority is fabricated".
  defp grant_scoped_caps(orchestrator_uri, session_uri, owner_uri) do
    # Phase 9 PR-3 (SPEC v3 §4): scope the orchestrator's bounded
    # caps to the session's workspace. The session must already be
    # bound (invariant 4 — Workspace.Loader.invoke_template /
    # SessionTemplate spawn paths call WorkspaceRegistry.bind);
    # without a binding we let it crash rather than silently grant
    # a cross-workspace cap.
    session_workspace =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, ws} ->
          ws

        :error ->
          raise "session #{URI.to_string(session_uri)} has no workspace binding " <>
                  "— cannot derive workspace_uri for orchestrator scope caps"
      end

    # Caps #1/#2 — unconditional scope-bounded delegation.
    unconditional_caps = [
      %Ezagent.Capability{
        kind: :session,
        behavior: :any,
        instance: {:within_session, session_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: DateTime.utc_now()
      },
      %Ezagent.Capability{
        kind: :agent,
        behavior: :any,
        instance: {:spawned_by, orchestrator_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: DateTime.utc_now()
      }
    ]

    # Caps #3/#4 — the two `Behavior.Template` caps, each gated by the
    # owner-cap preflight (§1.4 steps 1-4). `delegable_template_caps/3`
    # returns ONLY the caps whose preflight passed.
    template_caps =
      delegable_template_caps(owner_uri, session_workspace, orchestrator_uri)

    caps = unconditional_caps ++ template_caps

    target = URI.new!("#{URI.to_string(orchestrator_uri)}?action=identity.grant_cap")

    ctx = %{
      caller: owner_uri,
      caps: Ezagent.Entity.User.admin_caps(),
      reply: :ignore
    }

    results =
      Enum.map(caps, fn cap ->
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          ctx: ctx
        })
      end)

    case Enum.reject(results, &match?({:ok, _}, &1)) do
      [] -> :ok
      [err | _] -> {:error, {:scoped_cap_grant_failed, err}}
    end
  end

  # --- Step 9: register the orchestrator's MCP-server context ----------
  #
  # Phase 7 completion PR-5 — bind the orchestrator's
  # `(session, workspace, owner, parent-template)` context in
  # `Ezagent.Orchestrator.McpRegistry`.
  #
  # The orchestrator's `claude` reaches the 7 tools through the MCP
  # transport bridge (`priv/orchestrator_bridge.py` →
  # `Ezagent.Orchestrator.McpChannel`). That bridge can only present
  # the orchestrator's agent URI (token-authenticated). It cannot —
  # and must not — supply session / workspace / caps, because those
  # are exactly the context an untrusted `claude` process could spoof.
  #
  # Only the Generator knows the binding (it just spawned this
  # orchestrator INTO this session). Registering it here is what lets
  # the Channel reconstruct the correct, server-derived `%McpServer{}`
  # for THIS orchestrator from the URI alone
  # (`McpServer.from_orchestrator_uri/1`). `parent_template_uri` is the
  # SessionTemplate the session was instantiated from — `update_template`
  # needs it.
  defp register_orchestrator_mcp_context(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = owner_uri,
         %URI{} = parent_template_uri
       ) do
    Ezagent.Orchestrator.McpRegistry.register(orchestrator_uri,
      session_uri: session_uri,
      workspace_uri: workspace_uri,
      owner_uri: owner_uri,
      parent_template_uri: parent_template_uri
    )
  end

  # The owner-cap preflight (SPEC §1.4 steps 1-4) — returns the subset
  # of {cap #3, cap #4} the owner is actually authorized to delegate.
  #
  # For EACH of #3 (`:session_template`) and #4 (`:agent_template`)
  # independently:
  #
  # 1. load the owner's ACTUAL caps via `Ezagent.Identity.list_caps_for/1`
  #    (NOT `admin_caps()` — a real check against real authority);
  # 2. build the `needed` map for that delegated `{:within_workspace, ws}`
  #    `Behavior.Template` scope, using a representative template URI in
  #    the session's workspace;
  # 3. include the cap iff at least one owner cap `matches?/2` it.
  #
  # A failing preflight DROPS that one cap (fail closed) — the
  # orchestrator comes up without it and the corresponding tool DENIES
  # at dispatch. The Generator does NOT raise, does NOT abort the
  # session. No fabricated authority.
  defp delegable_template_caps(%URI{} = owner_uri, %URI{} = session_workspace, %URI{} = _orch_uri) do
    owner_caps = Ezagent.Identity.list_caps_for(owner_uri)
    workspace_name = session_workspace.host || "default"

    # (kind, representative-template-URI-in-workspace) for #3 and #4.
    candidates = [
      {:session_template, URI.new!("template://session/#{workspace_name}/_preflight@_")},
      {:agent_template, URI.new!("template://agent/#{workspace_name}/_preflight")}
    ]

    candidates
    |> Enum.filter(fn {kind, representative_uri} ->
      needed = %{
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        instance: representative_uri,
        workspace_uri: session_workspace
      }

      Enum.any?(owner_caps, &Ezagent.Capability.matches?(&1, needed))
    end)
    |> Enum.map(fn {kind, _representative_uri} ->
      %Ezagent.Capability{
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        instance: {:within_workspace, session_workspace},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: DateTime.utc_now()
      }
    end)
  end
end

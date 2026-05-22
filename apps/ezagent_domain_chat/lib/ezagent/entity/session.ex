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

    with {:ok, template_pid} <- ensure_template_alive(session_template_uri),
         :ok <- owner_instantiate_preflight(session_template_uri, owner_uri),
         {:ok, template_content} <- read_template_content(session_template_uri, template_pid),
         {:ok, session_uri} <- spawn_fresh_session(),
         {:ok, workspace_uri} <- default_workspace_for_session(session_uri),
         :ok <- Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri),
         {:ok, orchestrator_uri} <-
           spawn_orchestrator(session_uri, workspace_uri, owner_uri),
         {:ok, slot_instances} <-
           instantiate_agent_slots(template_content, workspace_uri, orchestrator_uri),
         :ok <-
           populate_working_copy(
             session_uri,
             template_content,
             slot_instances,
             workspace_uri,
             owner_uri
           ),
         :ok <- install_routing_rules(template_content, slot_instances, session_uri, owner_uri),
         :ok <- grant_scoped_caps(orchestrator_uri, session_uri, owner_uri),
         :ok <-
           register_orchestrator_mcp_context(
             orchestrator_uri,
             session_uri,
             workspace_uri,
             owner_uri,
             session_template_uri
           ) do
      {:ok, %{session_uri: session_uri, orchestrator_uri: orchestrator_uri}}
    else
      err -> err
    end
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
  defp read_template_content(%URI{} = session_template_uri, _template_pid) do
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

  defp spawn_fresh_session do
    # SPEC v3 §3.6 (Phase 9 PR-7) — sessions are 3-segment:
    # session://<template>/<workspace>/<name>. The Generator path
    # builds `session://generic/default/gen-<unique>` so dispatch can
    # extract workspace structurally without a registry lookup.
    unique_suffix = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.default_workspace_uri()
    workspace_name = workspace_uri.host
    session_uri = URI.new!("session://generic/#{workspace_name}/gen-#{unique_suffix}")

    case Ezagent.SpawnRegistry.spawn(session_uri) do
      {:ok, _pid} -> {:ok, session_uri}
      err -> err
    end
  end

  defp default_workspace_for_session(_session_uri) do
    # Phase 8c PR-E (Allen 2026-05-20): canonical name is
    # `workspace://default` per `Ezagent.URI` docs. The earlier
    # `workspace://generated-sessions` name was a Phase 7 stop-gap.
    # Sessions that don't override via SessionTemplate's
    # `default_workspace_uri` field land here.
    Ezagent.WorkspaceRegistry.default_workspace_uri()
  end

  defp spawn_orchestrator(session_uri, workspace_uri, owner_uri) do
    # Spawn the cc-orchestrator (PR 45 seed) under a fresh instance
    # name keyed to this session for traceability. SPEC v3 §3.6 PR-7
    # — orchestrator template is workspace-scoped to `default`.
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
  # Returns `{:ok, [{slot_name, agent_template_uri, worker_uri}]}` — the
  # working copy + the routing rules both consume this list.
  defp instantiate_agent_slots(template_content, %URI{} = workspace_uri, %URI{} = orchestrator_uri) do
    slots = normalize_agent_slots(Map.get(template_content, :agent_slots, []))

    Enum.reduce_while(slots, {:ok, []}, fn {slot_name, agent_template_uri}, {:ok, acc} ->
      case instantiate_one_slot(slot_name, agent_template_uri, workspace_uri, orchestrator_uri) do
        {:ok, worker_uri} ->
          {:cont, {:ok, [{slot_name, agent_template_uri, worker_uri} | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:agent_slot_failed, slot_name, reason}}}
      end
    end)
    |> case do
      {:ok, instances} -> {:ok, Enum.reverse(instances)}
      err -> err
    end
  end

  # Instantiate ONE slot: dispatch `template.instantiate` on its
  # AgentTemplate URI. `instance_name` is the slot name; the
  # `:instantiate` action builds the flavor-prefixed per-instance URI.
  defp instantiate_one_slot(slot_name, %URI{} = agent_template_uri, workspace_uri, orchestrator_uri) do
    with {:ok, _pid} <- ensure_template_alive(agent_template_uri),
         target <-
           URI.parse("#{URI.to_string(agent_template_uri)}?action=template.instantiate"),
         {:ok, %{workers: workers}} <-
           Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: %{
               instance_name: slot_name,
               workspace_uri: workspace_uri,
               spawned_by: orchestrator_uri
             },
             ctx: %{
               caller: orchestrator_uri,
               caps: Ezagent.Entity.User.admin_caps(),
               reply: {:caller_inbox, self()}
             }
           }) do
      case workers do
        [worker_uri | _] -> {:ok, worker_uri}
        [] -> {:error, :instantiate_returned_no_worker}
      end
    else
      {:error, _} = err -> err
      other -> {:error, {:unexpected_instantiate_result, other}}
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
  # `:chat` slice (PR-2's field). `agent_slots` carries
  # `{slot_name, source_agent_template_uri}` — the AgentTemplate URI, NOT
  # the live instance URI (the slot tuple is the durable truth; a worker
  # that dies + respawns keeps its slot's source template).
  # `routing_rules` carries `{matcher_ast, [slot_name]}` — receivers as
  # slot NAMES. Both come straight from the SessionTemplate content.
  #
  # Written via the `chat.set_working_copy` dispatch — Session is
  # `{:snapshot, :on_change}`, so the field survives a Session restart.
  defp populate_working_copy(
         %URI{} = session_uri,
         template_content,
         slot_instances,
         %URI{} = workspace_uri,
         %URI{} = owner_uri
       ) do
    agent_slots =
      Enum.map(slot_instances, fn {slot_name, agent_template_uri, _worker_uri} ->
        {slot_name, agent_template_uri}
      end)

    working_copy = %{
      agent_slots: agent_slots,
      routing_rules: normalize_routing_rules(Map.get(template_content, :routing_rules, [])),
      orchestrator_template_uri:
        Map.get(template_content, :orchestrator_template_uri) ||
          URI.parse("template://agent/default/cc-orchestrator"),
      default_workspace_uri:
        Map.get(template_content, :default_workspace_uri) || workspace_uri,
      description: Map.get(template_content, :description, "")
    }

    target = URI.parse("#{URI.to_string(session_uri)}?action=chat.set_working_copy")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{template_working_copy: working_copy},
           ctx: %{
             caller: owner_uri,
             caps: Ezagent.Entity.User.admin_caps(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{template_working_copy: _}} -> :ok
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
  # scoped to the session's workspace so workspace-scoped rules fire
  # (invariant 4). Receivers a slot name doesn't resolve to are skipped
  # — a rule whose every receiver is unknown is dropped.
  defp install_routing_rules(template_content, slot_instances, %URI{} = session_uri, %URI{} = owner_uri) do
    rules = normalize_routing_rules(Map.get(template_content, :routing_rules, []))

    slot_uri_by_name =
      Map.new(slot_instances, fn {slot_name, _tmpl, worker_uri} -> {slot_name, worker_uri} end)

    {:ok, workspace_uri} = default_workspace_for_session(session_uri)

    Enum.reduce_while(rules, :ok, fn {matcher_ast, receiver_slot_names}, :ok ->
      receiver_uris =
        receiver_slot_names
        |> Enum.map(&Map.get(slot_uri_by_name, to_string(&1)))
        |> Enum.reject(&is_nil/1)

      cond do
        receiver_uris == [] ->
          # No resolvable receiver — drop the rule (slot names that
          # don't map to a spawned worker can't route anywhere).
          {:cont, :ok}

        true ->
          case RuleStore.add(
                 EzagentDomainChat.Routing.MentionRouting,
                 matcher_ast,
                 receiver_uris,
                 owner_uri,
                 workspace_uri: workspace_uri
               ) do
            {:ok, _rule} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:routing_rule_failed, reason}}}
          end
      end
    end)
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
      {:session_template,
       URI.new!("template://session/#{workspace_name}/_preflight@_")},
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

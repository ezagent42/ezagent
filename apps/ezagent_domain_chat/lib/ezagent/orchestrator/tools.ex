defmodule Ezagent.Orchestrator.Tools do
  @moduledoc """
  Orchestrator MCP tool surface — the tools the cc-orchestrator
  (Decision #136, SPEC §7-3) exposes to the LLM it hosts.

  ## team-routing-unification §3.8 — SLOT RETIREMENT (clean cutover)

  The `agent_slot` mechanism (`add_agent_slot` / `remove_agent_slot` /
  `update_agent_template` / `write_matcher(receiver_slot_names)` and
  slot-name-based routing) is **REMOVED** — no backward-compat shim. A
  "slot" was a member with extra facets (spec §3.1); a multi-agent flow is
  a named **rule-set** of single-receiver rules sharing a prompt template,
  optionally fronted by a **legend**. The orchestrator now builds a team
  the same way SessionTemplate materialization does (PR-7), but one live
  call at a time, through MEMBER + RULE-SET oriented tools.

  ## The tools

  | Tool | Args | Effect |
  |---|---|---|
  | `add_managed_member` | source_agent_template_uri, role_name, in_session_template | Spawn a worker from a source AgentTemplate + join it as a session member with `role_name` + `in_session_template` (+ `source_template_uri`) facets |
  | `remove_member` | role_name | Remove a member by role_name; terminate the worker (if we spawned it) + prune routing rows naming it; reports rule-set impact (deleted/repointed rules) |
  | `define_rule_set_rule` | matcher_ast, receiver_role_name, rule_set, position, prompt_template_ref | Insert a single-receiver routing rule (targeting a member by role_name) into a named rule-set, with an optional prompt-template reference |
  | `define_prompt_template` | name, template | Install a named prompt template (rules reference it via `prompt_template_ref`; rendered at delivery — §3.4) |
  | `define_legend` | legend_name, member_role_names, bound_rule_set, fold | Front a rule-set with a `@legend` handle (member set by role_name) — §3.6 |
  | `update_template` | (no args) | Snapshot current session state → new version of current parent SessionTemplate |
  | `save_template_as` | new_name | Snapshot current session state → first version of NEW SessionTemplate |
  | `list_templates` | optional name_filter | Returns visible AgentTemplate + SessionTemplate URIs (CapBAC-filtered) |

  ## Authority (UNCHANGED from the slot tools — §3.8 "reuse existing authz")

  Every dispatch `ctx` carries `caps: <the orchestrator's delegated caps>`
  and `caller: <the orchestrator's URI>`. The new member/rule-set tools
  reuse the SAME caps the slot tools used — no new cap shape is invented:

  - **Cap #1** `{:within_session, S}` (`kind: :session, behavior: :any,
    action: :any`) authorises every Chat action on the session — the
    faceted `chat.join` (`add_managed_member`), `routing.add_rule`
    (`define_rule_set_rule`), `chat.set_legends` (`define_legend`),
    `chat.set_prompt_templates` (`define_prompt_template`).
  - **Cap #2** `{:spawned_by, orchestrator}` authorises `sandbox.destroy`
    on a worker THIS orchestrator spawned (`remove_member`).
  - **Caps #3/#4** template caps gate `list_templates` / `update_template`
    / `save_template_as`.

  A missing delegated cap returns `{:error, :unauthorized}` — fail closed,
  never a fallback to ambient authority. CapBAC is enforced AT EVERY
  DISPATCH.

  > **DEFERRED (spec §3.8):** the `{:manages, provenance}` manage-cap
  > authority on managed members — provenance + action `:manage` — is the
  > deferred creation-unification manage-cap. Members are added with
  > `role_name` + `source_template_uri` + `in_session_template` only;
  > **provenance is nil**. Authority reuses the existing orchestrator authz
  > above (no new cap shapes).

  > **SEAM / FOLLOW-UP (spec §3.8):** the slot tools' `update_agent_template`
  > carried a generation/respawn/repoint model (spawn a new generation,
  > repoint routes, terminate the old worker, rollback). The member model's
  > `source_template_uri` facet preserves the STATE needed to rebuild that,
  > but the member-level `update_member_template` (new generation + route
  > repoint + old-worker terminate) is NOT implemented in PR-8. It is a
  > clearly-marked follow-up: `add_managed_member` + `define_rule_set_rule`
  > + `define_legend` are sufficient for an orchestrator to build the
  > scenario-34 relay team. Generation/rollback returns when manage-cap
  > lands.

  ## Calling convention

  Every tool takes a trailing `opts` keyword list carrying the
  orchestrator's caller context (`:caller`, `:caps`, `:session_uri`,
  `:workspace_uri`, and for the template tools `:owner` /
  `:parent_template_uri`). The orchestrator MCP server fills these in from
  its bound per-orchestrator context before invoking — the LLM never
  supplies caller / caps / session context.

  ## Design locks (CI-gated, see tools_test.exs)

  - No `:fork` tool (Decision #141 — fork is a SessionTemplate registry
    verb, not an in-session orchestrator verb).
  - No `:grant_cap` tool (Decision #137 — cap delegation only happens at
    Generator boot, never mid-session).
  - **No slot mechanism** (§3.8 invariant gate, see
    `orchestrator_slot_retirement_test.exs`): `add_agent_slot` /
    `remove_agent_slot` / `update_agent_template` / `write_matcher` are
    GONE; `agent_slots` is dropped from the live Chat working copy.
  """

  require Logger

  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.Invocation

  @doc "The orchestration tool names."
  @spec tool_names() :: [atom()]
  def tool_names do
    [
      :add_managed_member,
      :remove_member,
      :define_rule_set_rule,
      :define_prompt_template,
      :define_legend,
      :update_template,
      :save_template_as,
      :list_templates
    ]
  end

  @doc "True iff `name` is one of the declared orchestration tools."
  @spec tool?(atom()) :: boolean()
  def tool?(name) when is_atom(name), do: name in tool_names()
  def tool?(_), do: false

  # === add_managed_member ================================================

  @doc """
  Spawn a worker agent from `source_agent_template_uri` and join it as a
  session member carrying `role_name` + `in_session_template` (+ the
  `source_template_uri` spawn-source facet). The member-model replacement
  for the retired `add_agent_slot` (spec §3.8 / §3.1).

  The member is reached only by an explicit rule targeting it (by role_name
  or URI) — the relay/team route is a rule-set rule (`define_rule_set_rule`)
  fronted by a legend (`define_legend`), NOT a slot-name route.

  Spawn-source state (`source_template_uri`) is recorded on the member's
  facet so a future respawn/regeneration (the deferred member-level
  `update_member_template`) can rebuild it. `provenance` is DEFERRED (nil)
  per §3.8 — management authority lands with the manage-cap.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, member_uri}` or `{:error, reason}`.
  """
  @spec add_managed_member(URI.t(), String.t(), boolean(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def add_managed_member(%URI{} = source_agent_template_uri, role_name, in_session_template, opts \\ [])
      when is_binary(role_name) and is_boolean(in_session_template) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri),
         # M2 (codex MAJOR) — PREFLIGHT the orchestrator's `{:within_session, S}`
         # session authority (cap #1) BEFORE spawning. Pre-fix the spawn ran
         # first and the `chat.join` cap check ran after, so a caller WITHOUT
         # the cap still spawned a worker, then the denied join's compensation
         # (`terminate_worker`, gated by the SAME possibly-insufficient caps)
         # could leave an ORPHAN. Failing closed here means an unauthorized
         # caller never spawns.
         :ok <- preflight_within_session_cap(caps, session_uri),
         {:ok, %URI{} = member_uri} <-
           spawn_member(source_agent_template_uri, role_name, session_uri, workspace_uri, caller) do
      facets =
        %{in_session_template: in_session_template, source_template_uri: source_agent_template_uri}
        |> Map.put(:role_name, role_name)

      case join_member(session_uri, member_uri, facets, caller, caps) do
        :ok ->
          {:ok, member_uri}

        {:error, reason} ->
          # spawn-succeeds / join-fails: tear down the worker WE just
          # spawned so the failed add leaves no orphan (mirrors PR-7
          # materialize_one_member's compensation).
          _ = terminate_worker(member_uri, caller, caps)
          {:error, reason}
      end
    end
  end

  # Spawn the member fresh from its source AgentTemplate. Reuses the PR-7
  # spawn path: `Agent.spawn_fresh/4` (records lineage under the
  # orchestrator `caller` + binds workspace ON fresh) + the session-unique,
  # flavor-prefixed instance name (so two sessions from one template don't
  # collide, and a respawn within the session is deterministic). On
  # `fresh?: false` (a worker already lives at the derived URI) we adopt it
  # idempotently — re-adding the same role within a session is a no-op spawn.
  defp spawn_member(
         %URI{} = source_template_uri,
         role_name,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = caller
       ) do
    # codex review P2 (2026-06-03) — read the source template content ONCE and
    # derive BOTH the flavor (→ member URI) and the spawn content from that
    # single snapshot. Previously the flavor came from a separate
    # `source_template_flavor/1` read and the spawn from a second
    # `read_source_template_content/1` read; a concurrent template edit between
    # the two could derive the member URI from the OLD flavor while spawning the
    # NEW content. Bridge routing derives flavor from the URI prefix, so that
    # divergence would route the sidecar via the wrong adapter / reject it.
    # One read = no divergence by construction.
    with {:ok, _pid} <- ensure_template_alive(source_template_uri),
         {:ok, content} <- read_source_template_content(source_template_uri),
         {:ok, flavor} <- content_flavor(content, source_template_uri) do
      do_spawn_member(content, flavor, source_template_uri, role_name, session_uri, workspace_uri, caller)
    end
  end

  defp do_spawn_member(
         content,
         flavor,
         %URI{} = source_template_uri,
         role_name,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = caller
       )
       when is_map(content) and is_binary(flavor) do
    instance_name =
      EzagentDomainChat.spawned_member_instance_name_public(
        flavor,
        source_template_uri,
        role_name,
        session_uri
      )

    # team-routing-unification LIVE-tier fix (2026-06-02) — spawn the member
    # through `Agent.spawn_from_template_content/4` (the `Template.instantiate`
    # chokepoint), NOT `Agent.spawn_fresh/4`. `spawn_fresh/4` only starts a bare
    # Agent Kind (`SpawnRegistry.spawn_detailed → Kind.spawn`) and NEVER reaches
    # `Template.instantiate`, so the plugin Template Class's instantiate — which
    # brings up the cc/codex/curl CLI + PTY, writes the per-agent config_dir, and
    # records `template_class`/`respawn_template_data` (the sandbox respawn state)
    # — never runs. Result pre-fix: a member ENTITY with no live CLI, so the
    # relay stalls at the first hop (no subprocess to receive `chat.receive`).
    # This is the SAME bug class codex PR #408 fixed for `ensure_orchestrator`
    # (`Session.spawn_orchestrator_via_template_content/5`); PR-8 left this path
    # on the old bare spawn. The deterministic Tier-1 gate spawns no real agents,
    # so only the LIVE tier exposed it.
    workspace_name =
      workspace_uri.host ||
        raise ArgumentError,
              "workspace_uri has no host (`workspace://<NAME>`) — got " <>
                inspect(workspace_uri)

    member_uri = Ezagent.URI.new!("entity://agent/#{workspace_name}/#{instance_name}")

    # `content` is the SAME snapshot the flavor (→ member_uri) was derived from
    # (codex P2) — no second read, so URI-flavor and spawned-content cannot diverge.
    with {:ok, _result} <-
           Ezagent.Entity.Agent.spawn_from_template_content(
             content,
             member_uri,
             caller,
             workspace_uri
           ) do
      {:ok, member_uri}
    end
  end

  # Read the source AgentTemplate Kind's content slice (the SOLE source of
  # truth), mirroring `Session.read_orchestrator_template_content/1`. The
  # content map is what `Agent.spawn_from_template_content/4` threads through
  # `AgentTemplate.to_template_data/2` + the plugin Template Class instantiate.
  defp read_source_template_content(%URI{} = template_uri) do
    case Ezagent.KindRegistry.lookup(template_uri) do
      :error ->
        {:error, {:source_template_not_alive, template_uri}}

      {:ok, pid} ->
        case safe_get_template_content(pid) do
          %{} = content when map_size(content) > 0 -> {:ok, content}
          _ -> {:error, {:source_template_not_populated, template_uri}}
        end
    end
  end

  defp safe_get_template_content(pid) do
    case :sys.get_state(pid, 500) do
      %{state: %{template: %{state: %{content: content}}}} when is_map(content) -> content
      %{state: %{template: %{content: content}}} when is_map(content) -> content
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # Faceted `chat.join` dispatch on the session — carries the PR-7 member
  # facets (role_name / in_session_template / source_template_uri). Gated by
  # the orchestrator's cap #1 ({:within_session, S}, behavior/action :any).
  defp join_member(%URI{} = session_uri, %URI{} = member_uri, facets, %URI{} = caller, caps)
       when is_map(facets) do
    # String-interpolation constructor (canonicalizes) rather than
    # `with_action/3` (which rejects a non-canonical session URI a test
    # fixture may pass) — same pattern as the routing/prompt-template/legend
    # dispatches below.
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: Map.put(facets, :member, member_uri),
           ctx: ctx(caller, caps)
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_join_result, other}}
    end
  end

  # Extract the `flavor` field from an ALREADY-READ source AgentTemplate
  # content snapshot. The flavor prefixes the spawned instance name so the
  # member Agent URI resolves to a flavor Kind module. codex P2 (2026-06-03):
  # callers MUST derive flavor from the SAME content snapshot they spawn from
  # (see `spawn_member/5`), so this takes the content rather than re-reading it.
  defp content_flavor(content, %URI{} = source_template_uri) when is_map(content) do
    case Map.get(content, :flavor) || Map.get(content, "flavor") do
      flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
      _ -> {:error, {:source_template_missing_flavor, source_template_uri}}
    end
  end

  # === remove_member =====================================================

  @doc """
  Remove a session member identified by `role_name`: terminate the worker
  (if THIS orchestrator spawned it — cap #2), prune routing rows naming it,
  and drop it from the session members. The member-model replacement for
  the retired `remove_agent_slot` (spec §3.8).

  Subsumes the `remove_agent_slot` rule-set observability (PR #519, todo
  #9): the result reports `deleted_rules` (rules cascade-DELETED because
  pruning the member left them with zero receivers — routing LOST, also
  `Logger.warning`ed) vs `repointed_rules` (rules that merely dropped the
  member but kept other receivers).

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  - `{:ok, %{status: :removed, deleted_rules: n, repointed_rules: m}}`
  - `{:ok, :already_removed}` — no member held that role_name.
  - `{:error, reason}` — preflight / authorization failure.
  """
  @spec remove_member(String.t(), keyword()) ::
          {:ok, :already_removed | %{status: :removed, deleted_rules: non_neg_integer(), repointed_rules: non_neg_integer()}}
          | {:error, term()}
  def remove_member(role_name, opts \\ []) when is_binary(role_name) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, _workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      case member_uri_for_role(session_uri, role_name) do
        nil ->
          {:ok, :already_removed}

        %URI{} = member_uri ->
          do_remove_member(session_uri, member_uri, caller, caps)
      end
    end
  end

  defp do_remove_member(%URI{} = session_uri, %URI{} = member_uri, %URI{} = caller, caps) do
    # Step 1 — terminate the worker (cap #2 gate). An unauthorized terminate
    # bails IMMEDIATELY — orchestrator B may not remove orchestrator A's
    # member. `terminate_worker/3` treats already-gone as idempotent :ok.
    case terminate_worker(member_uri, caller, caps) do
      :ok ->
        # Step 2 — prune routing rows naming this member (reporting
        # deleted/repointed counts — the rule-set impact §3.8 asks for).
        #
        # B2 (codex BLOCKER) — the prune is SCOPED to THIS session's rules
        # (`created_by == session_uri`, matching B1's stamp) so a member with
        # a same-named URI referenced by ANOTHER session's rules is never
        # touched; and a prune/repoint FAILURE FAILS the tool (returns
        # `{:error, _}`) instead of being swallowed into `deleted_rules: 0`
        # while removal silently continues.
        case prune_routing_rules_for(session_uri, member_uri) do
          {:ok, prune_counts} ->
            # Step 3 — drop the member from the session.
            _ = leave_member(session_uri, member_uri, caller, caps)

            {:ok,
             %{
               status: :removed,
               deleted_rules: prune_counts.deleted_rules,
               repointed_rules: prune_counts.repointed_rules
             }}

          {:error, _reason} = err ->
            # prune already labels its failures (`{:prune_failed, _}` /
            # `{:registry_reload_failed, _}`); propagate as-is. The member is
            # NOT dropped from the session — removal fails atomically rather
            # than reporting a false success with `deleted_rules: 0`.
            err
        end

      {:error, :unauthorized} = err ->
        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp leave_member(%URI{} = session_uri, %URI{} = member_uri, %URI{} = caller, caps) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.leave")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :cast,
      args: %{member: member_uri},
      ctx: ctx(caller, caps)
    })

    :ok
  end

  # PR3 2026-05-24 (Allen) — dispatches `sandbox.destroy`: runs the plugin
  # Template Class's `destroy_config_dir/2` FS cleanup AND schedules
  # Kind-process termination. Cap #2 ({:spawned_by, orchestrator}) is
  # checked at this dispatch — the orchestrator may terminate only workers
  # it itself spawned. Already-gone is idempotent success.
  defp terminate_worker(%URI{} = worker_uri, %URI{} = caller, caps) do
    target = Ezagent.URI.new!("#{URI.to_string(worker_uri)}?action=sandbox.destroy")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: ctx(caller, caps)
         }) do
      {:ok, %{destroyed: true, cleanup: :ok}} ->
        :ok

      {:ok, %{destroyed: true, cleanup: {:error, reason}}} ->
        {:error, {:terminated_with_cleanup_failure, reason}}

      {:ok, %{destroyed: true}} ->
        :ok

      {:ok, {:ok, :terminated}} -> :ok
      {:ok, :terminated} -> :ok
      {:error, :no_such_actor} -> :ok
      {:error, :not_ready} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_terminate_result, other}}
    end
  end

  # === define_rule_set_rule ==============================================

  @doc """
  Insert a SINGLE-RECEIVER routing rule into a named rule-set. The receiver
  is a member identified by `receiver_role_name` (resolved to its live
  member URI), and the rule may carry a `prompt_template_ref` (the named
  prompt template, rendered at delivery — §3.4). The member-model
  replacement for the retired `write_matcher(receiver_slot_names)` (§3.8).

  A rule-set is the explicit add/remove unit (§3.3): a named, ordered group
  of single-receiver rules forming one team flow. The relay is expressed as
  `{:mention, legend} → relay-cc`, `{:from, relay-cc} → relay-codex`, … —
  static rules, NO model-computed baton.

  The rule's scope-owning Kind is the orchestrator's Session (invariant 12);
  gated by cap #1 (`{:within_session, S}`). The receiver role_name resolves
  to a live member URI from the session's `:members` slice.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.
  Rule-set `opts`: `:rule_set` (string), `:position` (int, default 0),
  `:prompt_template_ref` (string | nil).

  Returns `{:ok, %{id: integer}}` or `{:error, reason}`.
  """
  @spec define_rule_set_rule(term(), String.t() | URI.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def define_rule_set_rule(matcher_ast, receiver_role_name, opts \\ []) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, matcher_json} <- normalize_matcher(matcher_ast),
         {:ok, receiver_uri} <- resolve_role_receiver(session_uri, receiver_role_name) do
      target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=routing.add_rule")

      add_opts = [
        workspace_uri: workspace_uri,
        source: "admin",
        # B1 (codex BLOCKER) — stamp tool-created rules with
        # `created_by = session_uri`, the SAME per-session identity PR-7
        # materialization uses (`install_one_rule`). Without it the rule
        # persists `created_by = nil` and `session_rule_set_rules/2` (the
        # template snapshot, keyed on `created_by == session_uri`) silently
        # drops it → the orchestrator-defined rule is LOST on save/materialize.
        created_by: session_uri,
        rule_set: Keyword.get(opts, :rule_set),
        position: Keyword.get(opts, :position, 0),
        prompt_template_ref: Keyword.get(opts, :prompt_template_ref)
      ]

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{
               table: EzagentDomainChat.Routing.MentionRouting,
               matcher_json: matcher_json,
               receivers: [URI.to_string(receiver_uri)],
               opts: add_opts
             },
             ctx: ctx(caller, caps)
           }) do
        {:ok, %{id: id}} -> {:ok, %{id: id}}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_add_rule_result, other}}
      end
    end
  end

  # Resolve a receiver to a member URI. A concrete `%URI{}` (a programmatic
  # caller's pre-resolved receiver) passes through; a magic token
  # (`$session_members` etc.) passes through (expanded at delivery); a
  # `receiver_role_name` STRING MUST resolve to a CURRENT member's role in
  # this session's live :members slice (the binding role_name → current URI,
  # which survives respawn — §3.1).
  #
  # M1 (codex MAJOR) — pre-fix this fell back to parsing ANY URI-shaped
  # string as a concrete receiver, so a `receiver_role_name` that wasn't a
  # member role but happened to parse as a URI (e.g. `entity://agent/x/y`)
  # BYPASSED member lookup and targeted a non-member. The tool's contract is
  # "target a member BY ROLE_NAME"; a dangling role_name is now rejected
  # `{:unknown_member_role, r}` instead of silently binding a non-member.
  defp resolve_role_receiver(_session_uri, %URI{} = uri), do: {:ok, uri}

  defp resolve_role_receiver(%URI{} = session_uri, role_name) when is_binary(role_name) do
    cond do
      Ezagent.Routing.Resolver.magic_token?(role_name) ->
        {:ok, role_name}

      true ->
        case Chat.role_name_to_uri(read_members(session_uri), role_name) do
          %URI{} = uri -> {:ok, uri}
          nil -> {:error, {:unknown_member_role, role_name}}
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

  # === define_prompt_template ============================================

  @doc """
  Install a named prompt template on the session (`name => template`).
  Rules reference it via `prompt_template_ref`; it is rendered at the
  delivery seam (`Chat.render_for_delivery/4`) — spec §3.4. The
  member-model team needs this so a rule-set rule's `prompt_template_ref`
  resolves to a real template (e.g. the relay's `telephone_hop`).

  Reuses the trusted-or-orchestrator authority of `chat.set_prompt_templates`
  (cap #1 `{:within_session, S}`). Merges into the existing map (does not
  clobber other named templates).

  Required `opts`: `:caller`, `:caps`, `:session_uri`.

  Returns `{:ok, %{prompt_templates: map}}` or `{:error, reason}`.
  """
  @spec define_prompt_template(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def define_prompt_template(name, template, opts \\ [])
      when is_binary(name) and is_binary(template) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, session_uri} <- require_opt(opts, :session_uri),
         # M3 (codex MAJOR) — reject a template missing the `{body}`
         # placeholder BEFORE installing it. Without `{body}` the renderer
         # (`Chat.render_for_delivery/4`) silently DROPS the original message
         # at delivery. Validate at the tool boundary so the orchestrator gets
         # `{:error, :body_placeholder_required}` instead of a live message loss.
         :ok <- Ezagent.Routing.PromptTemplate.validate(template) do
      merged = Map.put(read_prompt_templates(session_uri), name, template)

      target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.set_prompt_templates")

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{prompt_templates: merged},
             ctx: ctx(caller, caps)
           }) do
        {:ok, %{prompt_templates: _} = ok} -> {:ok, ok}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_set_prompt_templates_result, other}}
      end
    end
  end

  # === define_legend =====================================================

  @doc """
  Front a rule-set with a `@legend` handle (spec §3.6). A legend is a
  user-facing name that collapses the team (`member_set` by role_name) and
  triggers its flow (`bound_rule_set`). `@legend` resolves through the
  legend registry → the entry rule of `bound_rule_set` fires.

  Reuses `chat.set_legends` authority (cap #1 `{:within_session, S}`).
  Merges into the existing legend registry (does not clobber other legends).

  Required `opts`: `:caller`, `:caps`, `:session_uri`.

  Returns `{:ok, %{legends: map}}` or `{:error, reason}`.
  """
  @spec define_legend(String.t(), [String.t()], String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def define_legend(legend_name, member_role_names, bound_rule_set, fold, opts \\ [])
      when is_binary(legend_name) and is_list(member_role_names) and is_binary(bound_rule_set) and
             is_boolean(fold) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      entry = %{
        member_set: Enum.map(member_role_names, &to_string/1),
        bound_rule_set: bound_rule_set,
        fold: fold
      }

      merged = Map.put(read_legends(session_uri), legend_name, entry)

      target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.set_legends")

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{legends: merged},
             ctx: ctx(caller, caps)
           }) do
        {:ok, %{legends: _} = ok} -> {:ok, ok}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_set_legends_result, other}}
      end
    end
  end

  # === routing rule prune (KEPT — round-4 atomic-repoint primitive) ======

  # Drop the member URI from every routing rule's receiver set inside ONE
  # `Repo.transaction`. Rules left with zero receivers are force-deleted
  # (routing LOST — `Logger.warning`ed); rules with other receivers are
  # repointed. Returns `{:ok, %{deleted_rules, repointed_rules}}`. (todo #9
  # observability — the loss reaches the caller + the log.)
  #
  # B2 (codex BLOCKER) — SCOPED to THIS session's rules (`created_by ==
  # session_uri`, the B1/PR-7 stamp). Pre-fix it pruned EVERY rule whose
  # receivers named the member string, so a member with a same-named URI
  # referenced by ANOTHER session's rule-set could be deleted/mutated out
  # from under that session.
  defp prune_routing_rules_for(%URI{} = session_uri, %URI{} = member_uri) do
    table = EzagentDomainChat.Routing.MentionRouting
    member_str = URI.to_string(member_uri)
    session_str = URI.to_string(session_uri)

    txn =
      EzagentCore.Repo.transaction(fn ->
        rules = Ezagent.Routing.RuleStore.list(table)

        rules
        |> Enum.filter(fn rule ->
          rule.created_by == session_str and member_str in (rule.receivers || [])
        end)
        |> Enum.reduce_while({[], 0}, fn rule, {deleted_meta, repointed} ->
          remaining =
            (rule.receivers || [])
            |> Enum.reject(fn r -> r == member_str end)
            |> Enum.uniq()

          {result, acc} =
            if remaining == [] do
              {Ezagent.Routing.RuleStore.delete(rule.id, force: true),
               {[{rule.id, Map.get(rule, :matcher_data, :unknown)} | deleted_meta], repointed}}
            else
              {Ezagent.Routing.RuleStore.update_receivers(rule.id, remaining, rule.enabled),
               {deleted_meta, repointed + 1}}
            end

          case result do
            :ok -> {:cont, acc}
            {:error, reason} -> EzagentCore.Repo.rollback({:prune_failed, reason})
          end
        end)
      end)

    case txn do
      {:ok, {deleted_meta, repointed}} ->
        case reload_registry(table) do
          :ok ->
            Enum.each(deleted_meta, fn {id, matcher} ->
              Logger.warning(
                "remove_member routing GC: force-deleted routing rule " <>
                  "id=#{inspect(id)} matcher=#{inspect(matcher)} " <>
                  "because removing member #{member_str} left it with ZERO receivers. " <>
                  "Routing to this rule is LOST — re-adding the member does NOT restore it."
              )
            end)

            {:ok, %{deleted_rules: length(deleted_meta), repointed_rules: repointed}}

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:prune_failed, e}}
  catch
    kind, reason -> {:error, {:prune_failed, {kind, reason}}}
  end

  defp reload_registry(table) do
    Ezagent.Routing.RuleStore.load_into_registry(table)
    :ok
  rescue
    e -> {:error, {:registry_reload_failed, e}}
  catch
    _, reason -> {:error, {:registry_reload_failed, reason}}
  end

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

  Returns `{:ok, new_template_uri}`. If the parent SessionTemplate hash has
  been deleted, returns `{:error, :parent_template_deleted}` (use
  `save_template_as`).
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
      action: :any,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: DateTime.utc_now()
    }

    target = Ezagent.URI.new!("#{URI.to_string(owner_uri)}?action=identity.grant_cap")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{cap: cap},
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("template-materialize"),
             caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
             reply: :ignore
           }
         }) do
      {:ok, _} ->
        :ok

      other ->
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
    |> Enum.map(fn row -> Ezagent.URI.new!(row.uri) end)
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

  # M2 — true iff `caps` carries the orchestrator's cap #1
  # (`{:within_session, session_uri}` on the `:session` kind). Mirrors the
  # session-side `Chat.orchestrator_cap_present?/1` check so the preflight
  # decision matches the authority the deferred `chat.join` would enforce.
  # `:ok` / `{:error, :unauthorized}` — fail closed.
  defp preflight_within_session_cap(caps, %URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    authorized? =
      caps
      |> to_cap_set()
      |> Enum.any?(fn
        %Ezagent.Capability{kind: :session, instance: {:within_session, %URI{} = s}} ->
          URI.to_string(s) == session_str

        _ ->
          false
      end)

    if authorized?, do: :ok, else: {:error, :unauthorized}
  end

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
    workspace_name =
      workspace_uri.host ||
        raise ArgumentError,
              "workspace_uri has no host (`workspace://<NAME>`) — got " <>
                inspect(workspace_uri) <>
                ". Per SPEC #324 rev 3 / PR #335, there is NO silent default workspace " <>
                "fallback; callers must pass a workspace URI with an explicit name."

    representative =
      case kind do
        :agent_template -> Ezagent.URI.new!("template://agent/#{workspace_name}/_catalog")
        :session_template -> Ezagent.URI.new!("template://session/#{workspace_name}/_catalog@_")
      end

    needed = %{
      kind: kind,
      behavior: Ezagent.Behavior.Template,
      action: :any,
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

  # --- live session-slice reads ------------------------------------------

  # Read the live Session Kind's :chat slice (two-container — unwrap to its
  # persistent :state). Empty map when the session is not alive.
  defp read_chat_slice(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Chat.state_slice(), %{})

        Map.get(chat_slice, :state, chat_slice)

      :error ->
        %{}
    end
  end

  defp read_members(%URI{} = session_uri),
    do: Map.get(read_chat_slice(session_uri), :members, %{})

  defp read_prompt_templates(%URI{} = session_uri),
    do: Map.get(read_chat_slice(session_uri), :prompt_templates, %{})

  defp read_legends(%URI{} = session_uri),
    do: Map.get(read_chat_slice(session_uri), :legends, %{})

  defp member_uri_for_role(%URI{} = session_uri, role_name) when is_binary(role_name) do
    Chat.role_name_to_uri(read_members(session_uri), role_name)
  end

  # Build the template-shaped working-copy slice from the live session for
  # update_template / save_template_as. The slot-era `agent_slots` is GONE
  # (§3.8) — a SessionTemplate snapshots `members` (those with
  # `in_session_template: true`), `prompt_templates`, `legends`, and the
  # session's rule-set routing rows (PR-7 SessionTemplate content shape).
  defp build_working_copy(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = _caller_uri,
         parent_uri
       ) do
    slice = read_chat_slice(session_uri)

    orchestrator_template_uri =
      Map.get(slice, :orchestrator_template_uri) ||
        get_in(slice, [:template_working_copy, :orchestrator_template_uri]) ||
        Ezagent.URI.new!("template://agent/system/cc-orchestrator")

    members = Map.get(slice, :members, %{})

    template_members =
      members
      |> Enum.filter(fn {_uri, meta} -> Map.get(meta, :in_session_template) == true end)
      |> Enum.map(fn {uri, meta} ->
        %{
          uri: uri,
          role_name: Map.get(meta, :role_name),
          in_session_template: true,
          source_template_uri: Map.get(meta, :source_template_uri)
        }
      end)
      |> Enum.sort_by(&inspect/1)

    content = %{
      description: Map.get(slice, :description, ""),
      members: template_members,
      prompt_templates: Map.get(slice, :prompt_templates, %{}),
      legends: Map.get(slice, :legends, %{}),
      routing_rules: session_rule_set_rules(session_uri, workspace_uri),
      orchestrator_template_uri: orchestrator_template_uri,
      default_workspace_uri: workspace_uri,
      parent_template_uri: parent_uri
    }

    {:ok, content}
  end

  # Snapshot the session's rule-set routing rows (the rules this session
  # created, keyed by `created_by = session_uri`) into the template-shaped
  # `routing_rules` list materialization re-installs. Receivers that map to
  # an `in_session_template: true` member are rewritten back to that
  # member's role_name (so the snapshot is URI-independent + re-resolves on
  # instantiate); other receivers pass through as concrete URI strings.
  defp session_rule_set_rules(%URI{} = session_uri, %URI{} = _workspace_uri) do
    table = EzagentDomainChat.Routing.MentionRouting
    session_str = URI.to_string(session_uri)
    uri_to_role = uri_to_role_map(session_uri)

    table
    |> safe_rule_list()
    |> Enum.filter(fn r -> r.created_by == session_str and not is_nil(r.rule_set) end)
    |> Enum.flat_map(fn r ->
      case Ezagent.Routing.Matcher.from_json(r.matcher_data) do
        {:ok, matcher} ->
          [
            %{
              matcher: matcher,
              receivers: Enum.map(r.receivers || [], fn rec -> Map.get(uri_to_role, rec, rec) end),
              rule_set: r.rule_set,
              position: r.position,
              prompt_template_ref: r.prompt_template_ref
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(fn r -> {r.rule_set, r.position} end)
  end

  defp uri_to_role_map(%URI{} = session_uri) do
    read_members(session_uri)
    |> Enum.flat_map(fn
      {%URI{} = uri, %{role_name: role}} when is_binary(role) -> [{URI.to_string(uri), role}]
      _ -> []
    end)
    |> Map.new()
  end

  defp safe_rule_list(table) do
    Ezagent.Routing.RuleStore.list(table)
  rescue
    _ -> []
  end
end

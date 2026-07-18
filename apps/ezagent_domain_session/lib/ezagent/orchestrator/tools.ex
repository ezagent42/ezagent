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
  | `update_member_template` | role_name, new_source_template_uri | Swap a managed member's source AgentTemplate + REGENERATE the member (terminate old worker → spawn fresh from the new template at the same role_name → re-join with the new `source_template_uri` facet) — PR-6, domain.agent |
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

  > **`update_member_template` — IMPLEMENTED (PR-6, domain.agent).** The
  > slot tools' `update_agent_template` carried a generation/respawn/repoint
  > model; the member model's `source_template_uri` facet preserves the
  > STATE needed to rebuild that. PR-6 lands the member-level
  > `update_member_template` as a destroy-and-recreate REGENERATE (terminate
  > old worker → spawn fresh from the NEW template at the same `role_name` →
  > re-join with the new `source_template_uri` facet). No route repoint is
  > needed: `role_name` is the stable binding, so rules keyed on it
  > re-resolve to the new worker by construction (§3.1). Authority reuses the
  > existing orchestrator caps (cap #1 `{:within_session, S}` + cap #2
  > `{:spawned_by, orchestrator}`) — NO new cap shape; manage-cap +
  > `desired_caps` live-grant remain deferred to #533 / PR-5 reconfigure (see
  > the tool's `@doc` + `docs/notes/pr6-desired-skills-caps.md`).

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

  alias Ezagent.ActionSet.Session
  alias Ezagent.Invocation
  alias Ezagent.Orchestrator.Tools.DefinitionSync
  alias Ezagent.Orchestrator.Tools.MemberTemplate
  alias Ezagent.Orchestrator.Tools.Migration
  alias Ezagent.Orchestrator.Tools.Participants
  alias Ezagent.Orchestrator.Tools.Templates
  alias Ezagent.Session.Config.Catalog

  @doc "The orchestration tool names."
  @spec tool_names() :: [atom()]
  defdelegate tool_names(), to: Catalog, as: :core_names

  @doc "True iff `name` is one of the declared orchestration tools."
  @spec tool?(atom()) :: boolean()
  def tool?(name), do: is_atom(name) and name in tool_names()

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
  def add_managed_member(
        %URI{} = source_agent_template_uri,
        role_name,
        in_session_template,
        opts \\ []
      )
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
         :ok <- preflight_within_session_cap(caps, session_uri, :join),
         {:ok, %URI{} = member_uri} <-
           spawn_member(
             source_agent_template_uri,
             role_name,
             session_uri,
             workspace_uri,
             caller,
             caps
           ),
         :ok <-
           Ezagent.Orchestrator.Tools.SpawnAuthority.grant(
             member_uri,
             caller,
             workspace_uri
           ) do
      facets =
        %{
          in_session_template: in_session_template,
          source_template_uri: source_agent_template_uri
        }
        |> Map.put(:role_name, role_name)

      case join_member(session_uri, member_uri, facets, caller, caps) do
        :ok ->
          with :ok <-
                 DefinitionSync.member(session_uri, workspace_uri, caller, member_uri, facets,
                   caps: caps
                 ) do
            {:ok, member_uri}
          end

        {:error, reason} ->
          # spawn-succeeds / join-fails: tear down the worker WE just
          # spawned so the failed add leaves no orphan (mirrors PR-7
          # materialize_one_member's compensation).
          _ = terminate_worker(member_uri, caller, caps)
          {:error, reason}
      end
    end
  end

  @doc """
  Add a participant by reference.

  `ref` may name an existing entity URI (join only), a source AgentTemplate URI
  (spawn + join through `add_managed_member/4`), or a manifest file path (load,
  spawn from manifest, then join). Existing humans receive invited join
  authority and the session-scoped participation tier before the tool returns.
  """
  @spec add_participant(String.t() | URI.t(), String.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  defdelegate add_participant(ref, role_name, opts \\ []), to: Participants

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
         %URI{} = caller,
         caps
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
      do_spawn_member(
        content,
        flavor,
        source_template_uri,
        role_name,
        session_uri,
        workspace_uri,
        caller,
        caps
      )
    end
  end

  defp do_spawn_member(
         content,
         flavor,
         %URI{} = source_template_uri,
         role_name,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps
       )
       when is_map(content) and is_binary(flavor) do
    instance_name =
      EzagentDomainInstanceMessage.spawned_member_instance_name_public(
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
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

    member_uri = Ezagent.URI.agent(workspace_name, instance_name)

    # `content` is the SAME snapshot the flavor (→ member_uri) was derived from
    # (codex P2) — no second read, so URI-flavor and spawned-content cannot diverge.
    with {:ok, _result} <-
           Ezagent.Domain.Agent.materialize_from_template(
             content,
             member_uri,
             caller,
             workspace_uri,
             caller: caller,
             caps: caps,
             source_template_uri: source_template_uri
           ) do
      {:ok, member_uri}
    end
  end

  # Read the source AgentTemplate Kind's content slice (the SOLE source of
  # truth), mirroring `Session.read_orchestrator_template_content/1`. The
  # content map is what `Agent.spawn_from_template_content/4` threads through
  # `AgentTemplate.to_template_data/2` + the plugin Template Class instantiate.
  #
  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate.preflight_new_template/4`.
  @doc false
  def read_source_template_content(%URI{} = template_uri) do
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
    case Ezagent.Kind.runtime_view(pid) do
      {:ok, %{state: %{template: %{state: %{content: content}}}}} when is_map(content) ->
        content

      {:ok, %{state: %{template: %{content: content}}}} when is_map(content) ->
        content

      _ ->
        %{}
    end
  catch
    :exit, _ -> %{}
  end

  # Faceted `chat.join` dispatch on the session — carries the PR-7 member
  # facets (role_name / in_session_template / source_template_uri). Gated by
  # the orchestrator's cap #1 ({:within_session, S}, behavior/action :any).
  #
  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate` (regenerate join +
  # rollback re-join).
  @doc false
  def join_member(%URI{} = session_uri, %URI{} = member_uri, facets, %URI{} = caller, caps)
      when is_map(facets) do
    # String-interpolation constructor (canonicalizes) rather than
    # `with_action/3` (which rejects a non-canonical session URI a test
    # fixture may pass) — same pattern as the routing/prompt-template/legend
    # dispatches below.
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: Map.put(facets, :member, member_uri),
           ctx: ctx(caller, caps),
           origin: :trusted_internal
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
  #
  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate.preflight_new_template/4`.
  @doc false
  def content_flavor(content, %URI{} = source_template_uri) when is_map(content) do
    case Map.get(content, :flavor) || Map.get(content, "flavor") do
      flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
      _ -> {:error, {:source_template_missing_flavor, source_template_uri}}
    end
  end

  # === update_member_template ============================================

  @doc """
  Swap a managed member's source AgentTemplate + REGENERATE the member
  (terminate old worker → spawn fresh from the new template at the same
  `role_name` → re-join + repoint routing rules old→new).

  Thin wrapper preserving the public `Tools.update_member_template/3` entry
  for external callers (orchestrator MCP `run_tool` dispatch + `Tools.invoke/2`
  `apply/3` + tests). The regeneration + routing-rule-repoint implementation
  was extracted to `Ezagent.Orchestrator.Tools.MemberTemplate` (PR-3S) — see
  that module's `update_member_template/3` for the full contract + behavior.
  """
  @spec update_member_template(String.t(), URI.t(), keyword()) ::
          {:ok, %{member_uri: URI.t(), regenerated: true}} | {:error, term()}
  def update_member_template(role_name, %URI{} = new_source_template_uri, opts \\ []),
    do: MemberTemplate.update_member_template(role_name, new_source_template_uri, opts)

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
          {:ok,
           :already_removed
           | %{
               status: :removed,
               deleted_rules: non_neg_integer(),
               repointed_rules: non_neg_integer()
             }}
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

  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate` (regenerate leave +
  # rollback leave).
  @doc false
  def leave_member(%URI{} = session_uri, %URI{} = member_uri, %URI{} = caller, caps) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.leave")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :cast,
      args: %{member: member_uri},
      ctx: ctx(caller, caps),
      origin: :trusted_internal
    })

    :ok
  end

  # PR3 2026-05-24 (Allen) — dispatches `sandbox.destroy`: runs the plugin
  # Template Class's `destroy_config_dir/2` FS cleanup AND schedules
  # Kind-process termination. Cap #2 ({:spawned_by, orchestrator}) is
  # checked at this dispatch — the orchestrator may terminate only workers
  # it itself spawned. Already-gone is idempotent success.
  #
  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate` (regenerate teardown +
  # rollback teardown).
  @doc false
  def terminate_worker(%URI{} = worker_uri, %URI{} = caller, caps) do
    target = Ezagent.URI.new!("#{URI.to_string(worker_uri)}?action=sandbox.destroy")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: ctx(caller, caps),
           origin: :trusted_internal
         }) do
      {:ok, %{destroyed: true, cleanup: :ok}} ->
        :ok

      {:ok, %{destroyed: true, cleanup: {:error, reason}}} ->
        {:error, {:terminated_with_cleanup_failure, reason}}

      {:ok, %{destroyed: true}} ->
        :ok

      {:ok, {:ok, :terminated}} ->
        :ok

      {:ok, :terminated} ->
        :ok

      {:error, :no_such_actor} ->
        :ok

      {:error, :not_ready} ->
        :ok

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_terminate_result, other}}
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
      target = Ezagent.URI.with_action(session_uri, :routing, :add_rule)

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
               table: EzagentDomainInstanceMessage.Routing.MentionRouting,
               matcher_json: matcher_json,
               receivers: [Ezagent.URI.stable_key(receiver_uri)],
               opts: add_opts
             },
             ctx: ctx(caller, caps),
             origin: :trusted_internal
           }) do
        {:ok, %{id: id}} ->
          with :ok <-
                 DefinitionSync.rule(
                   session_uri,
                   workspace_uri,
                   caller,
                   matcher_json,
                   receiver_role_name,
                   Keyword.put(add_opts, :caps, caps)
                 ) do
            {:ok, %{id: id}}
          end

        {:error, _} = err ->
          err

        other ->
          {:error, {:unexpected_add_rule_result, other}}
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
        case Session.role_name_to_uri(read_members(session_uri), role_name) do
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
  delivery seam (`Session.render_for_delivery/4`) — spec §3.4. The
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
         # (`Session.render_for_delivery/4`) silently DROPS the original message
         # at delivery. Validate at the tool boundary so the orchestrator gets
         # `{:error, :body_placeholder_required}` instead of a live message loss.
         :ok <- Ezagent.Routing.PromptTemplate.validate(template) do
      merged = Map.put(read_prompt_templates(session_uri), name, template)

      target =
        Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.set_prompt_templates")

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{prompt_templates: merged},
             ctx: ctx(caller, caps),
             origin: :trusted_internal
           }) do
        {:ok, %{prompt_templates: _} = ok} ->
          with :ok <-
                 DefinitionSync.prompt_template(session_uri, caller, name, template, caps: caps) do
            {:ok, ok}
          end

        {:error, _} = err ->
          err

        other ->
          {:error, {:unexpected_set_prompt_templates_result, other}}
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

      target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.set_legends")

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{legends: merged},
             ctx: ctx(caller, caps),
             origin: :trusted_internal
           }) do
        {:ok, %{legends: _} = ok} ->
          with :ok <-
                 DefinitionSync.legend(
                   session_uri,
                   caller,
                   legend_name,
                   member_role_names,
                   bound_rule_set,
                   fold,
                   caps: caps
                 ) do
            {:ok, ok}
          end

        {:error, _} = err ->
          err

        other ->
          {:error, {:unexpected_set_legends_result, other}}
      end
    end
  end

  # === routing rule prune (F7 PR-A: extracted to shared module) ===========
  #
  # The atomic session-scoped prune primitive MOVED to
  # `Ezagent.ActionSet.Session.RoutingPrune` so the isomorphic
  # `Behavior.Session.remove_participant` (F7 PR-A) and this orchestrator
  # `remove_member` path share ONE implementation (no fork — cross-op
  # consistency). These thin delegators preserve the existing internal call
  # sites + the PR-3S public `reload_registry/1` (used by
  # `Tools.MemberTemplate.repoint_routing_rules/3`).
  defp prune_routing_rules_for(%URI{} = session_uri, %URI{} = member_uri),
    do: Ezagent.ActionSet.Session.RoutingPrune.prune_routing_rules_for(session_uri, member_uri)

  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate.repoint_routing_rules/3`.
  @doc false
  defdelegate reload_registry(table), to: Ezagent.ActionSet.Session.RoutingPrune

  @doc "Snapshot the live session as a new version of the current parent SessionTemplate."
  @spec update_template(keyword()) :: {:ok, URI.t()} | {:error, term()}
  defdelegate update_template(opts \\ []), to: Templates

  @doc "Snapshot the live session as the first version of a new SessionTemplate."
  @spec save_template_as(String.t(), keyword()) :: {:ok, URI.t()} | {:error, term()}
  defdelegate save_template_as(new_name, opts \\ []), to: Templates

  @doc "Migrate the live session to an immutable target SessionTemplate URI."
  @spec migrate_session(URI.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate migrate_session(target_session_template_uri, opts \\ []), to: Migration

  @doc "List visible AgentTemplate and SessionTemplate URIs, per-kind cap-gated."
  @spec list_templates(String.t() | nil, keyword()) ::
          {:ok, %{agent_templates: [URI.t()], session_templates: [URI.t()]}}
          | {:error, term()}
  defdelegate list_templates(name_filter \\ nil, opts \\ []), to: Templates

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

  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate` preflight helpers.
  @doc false
  def to_cap_set(%MapSet{} = caps), do: caps
  def to_cap_set(caps) when is_list(caps), do: MapSet.new(caps)
  def to_cap_set(_), do: MapSet.new()

  # M2 — true iff `caps` carries the orchestrator's full cap #1 requirement:
  # Session behavior + any action over this concrete session/workspace. This
  # uses the same provenance-aware full capability predicate as runtime; a
  # narrowed cap of the wrong behavior/action cannot pass before side effects.
  #
  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate.update_member_template/3`.
  @doc false
  def preflight_within_session_cap(caps, %URI{} = session_uri, action)
      when is_atom(action) do
    needed = %{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: session_uri,
      workspace_uri: Ezagent.Capability.workspace_of(session_uri)
    }

    authorized? = Ezagent.Capability.Authorization.authorizes?(to_cap_set(caps), needed)

    if authorized?, do: :ok, else: {:error, :unauthorized}
  end

  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate.update_member_template/3`.
  @doc false
  def require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_opt, key}}
      v -> {:ok, v}
    end
  end

  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate.preflight_new_template/4`.
  @doc false
  def ensure_template_alive(%URI{} = template_uri) do
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

  # --- live session-slice reads ------------------------------------------

  # Read the live Session Kind's :chat slice (two-container — unwrap to its
  # persistent :state). Empty map when the session is not alive.
  defp read_chat_slice(%URI{} = session_uri) do
    case Ezagent.Kind.get_raw_slice(session_uri, :session) do
      {:ok, chat_slice} ->
        Map.get(chat_slice, :state, chat_slice)

      {:error, _} ->
        %{}
    end
  end

  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate.capture_member_facets/2`.
  @doc false
  def read_members(%URI{} = session_uri),
    do: Map.get(read_chat_slice(session_uri), :members, %{})

  defp read_prompt_templates(%URI{} = session_uri),
    do: Map.get(read_chat_slice(session_uri), :prompt_templates, %{})

  defp read_legends(%URI{} = session_uri),
    do: Map.get(read_chat_slice(session_uri), :legends, %{})

  # PUBLIC (PR-3S): also called by `Tools.MemberTemplate.resolve_existing_member/2`.
  @doc false
  def member_uri_for_role(%URI{} = session_uri, role_name) when is_binary(role_name) do
    Session.role_name_to_uri(read_members(session_uri), role_name)
  end
end

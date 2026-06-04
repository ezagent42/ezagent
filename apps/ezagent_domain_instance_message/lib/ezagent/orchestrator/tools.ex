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

  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.Invocation

  @doc "The orchestration tool names."
  @spec tool_names() :: [atom()]
  def tool_names do
    [
      :add_managed_member,
      :update_member_template,
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

  # codex round-9 P2 — like `do_spawn_member/7` but REQUIRES a FRESH spawn:
  # `Agent.spawn_from_template_content/4` returns `fresh?: false` when it
  # ADOPTED a pre-existing worker at the derived URI (residue from a prior
  # failed regenerate rollback, or a concurrent spawn). A regenerate must NOT
  # adopt — binding the role to a worker IT didn't create/re-materialize would
  # carry stale/foreign config + break later lineage-gated removal. Reject
  # adoption so the swap fails closed (the spawn-first ordering then leaves the
  # OLD member fully intact). `add_managed_member` deliberately ADOPTS (re-add
  # is idempotent); a regenerate does NOT.
  defp spawn_fresh_member(
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
      EzagentDomainInstanceMessage.spawned_member_instance_name_public(
        flavor,
        source_template_uri,
        role_name,
        session_uri
      )

    workspace_name =
      workspace_uri.host ||
        raise ArgumentError,
              "workspace_uri has no host (`workspace://<NAME>`) — got " <> inspect(workspace_uri)

    member_uri = Ezagent.URI.new!("entity://agent/#{workspace_name}/#{instance_name}")

    case Ezagent.Entity.Agent.spawn_from_template_content(content, member_uri, caller, workspace_uri) do
      {:ok, %{fresh?: true}} ->
        {:ok, member_uri}

      {:ok, %{fresh?: false}} ->
        {:error, {:replacement_uri_already_live, member_uri}}

      {:ok, _other} ->
        # No fresh? signal (legacy 2-tuple normalized to fresh?: false by the
        # spawn path) — treat conservatively as adoption + reject.
        {:error, {:replacement_uri_already_live, member_uri}}

      {:error, _} = err ->
        err
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

  # === update_member_template ============================================

  @doc """
  Swap a managed member's source AgentTemplate to `new_source_template_uri`
  and **regenerate** the member from the new template (PR-6, domain.agent).

  The member-level realization of the slot-era `update_agent_template`'s
  generation/respawn/repoint model, marked "SEAM / FOLLOW-UP" in this
  module's moduledoc. The `source_template_uri` facet `add_managed_member`
  records preserves the spawn-source state this rebuild needs.

  ## Regenerate = spawn-new-then-retire-old (atomic-safe, structural)

  A swapped template can change flavor / cwd / config_dir / skills / caps.
  Rather than live-mutate a running PTY (the fragile path
  `feedback_let_it_crash_no_workarounds` rejects, and the concern PR-5's
  `reconfigure` Manage hook owns), `update_member_template` regenerates by
  building the replacement BEFORE retiring the original, so an ordinary
  runtime failure NEVER leaves the session with a deleted member + no
  replacement:

    1. Preflights cap #1 `{:within_session, S}` (same authority as
       `add_managed_member` — §3.8 "reuse existing authz"; NO new cap).
    2. Resolves `role_name` → the CURRENT member URI (fails
       `{:unknown_member_role, _}` if no member holds that role).
    3. Reads + VALIDATES the NEW template (via `to_template_data/2`) and
       captures the old member's `in_session_template` facet — all BEFORE
       touching anything. An invalid new template fails closed here.
    4. Derives the new member URI (instance name is template-source-hashed).
       A swap that hashes to the SAME URI (an in-place edit of the same
       template) is rejected `{:error, :same_member_uri_use_reconfigure}` —
       in-place live re-materialization is PR-5's `reconfigure` hook.
    5. NON-DESTRUCTIVELY preflights cap #2 (`Sandbox.destroy` on the old
       member — the SAME boundary `remove_member` enforces, matched via
       `Capability.matches?/2`). Fails closed BEFORE spawning if the caller
       may not retire that member.
    6. SPAWNS the new worker (at the new URI; the old still lives). Requires a
       FRESH spawn — rejects adopting a pre-existing worker at that URI.
    7. Repoints the session's routing rules old→new — BOTH receiver lists
       AND `{:from, <uri>}` sender matchers (incl. nested `and`/`or`/`not`
       combinators) for relay-chain downstream hops.
    8. Leaves the old member (frees the role) + joins the new member with the
       NEW `source_template_uri` facet + preserved `in_session_template` flag.
       **This join is the COMMIT POINT.**
    9. Retires the OLD worker LAST + BEST-EFFORT (authority already proven; a
       cleanup error is warned, not rolled back).

  On any failure BEFORE the commit (join), the swap rolls back: leave the
  replacement, repoint routes BACK, terminate the replacement, re-join the
  (still-alive) old member with its full original facets — the session
  returns to its pre-call state.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, %{member_uri: URI.t(), regenerated: true}}` or
  `{:error, reason}` (notably `:same_member_uri_use_reconfigure`,
  `{:invalid_new_template, _}`, `{:unknown_member_role, _}`,
  `:unauthorized`).

  > **Overlap (PR-5 #533):** the live re-apply of `desired_caps` (grant to
  > the member identity) + live skill re-copy is the re-materialization
  > seam PR-5's `reconfigure` owns. PR-6 lands the member-template SWAP +
  > the domain desired-skills/caps DATA model (threaded by
  > `AgentTemplate.to_template_data/2`); the fresh spawn re-runs the
  > flavor's `instantiate/3` (which already places skills, e.g. cc's
  > role-based copy), so a destroy-and-recreate regenerate re-materializes
  > by construction. Granting `desired_caps` into the live identity is the
  > flagged follow-up (see docs/notes/pr6-desired-skills-caps.md §"Flagged
  > design ambiguities").
  """
  @spec update_member_template(String.t(), URI.t(), keyword()) ::
          {:ok, %{member_uri: URI.t(), regenerated: true}} | {:error, term()}
  def update_member_template(role_name, %URI{} = new_source_template_uri, opts \\ [])
      when is_binary(role_name) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri),
         # Fail closed BEFORE resolving/terminating anything — an
         # unauthorized caller never mutates the team (mirrors
         # add_managed_member's M2 preflight).
         :ok <- preflight_within_session_cap(caps, session_uri),
         # codex round-10 P1 — `preflight_within_session_cap/2` only matches
         # kind + `{:within_session, S}` (it ignores behavior/action, like
         # `add_managed_member`). A regenerate is DESTRUCTIVE: it `chat.leave`s
         # the old member then `chat.join`s the replacement. A caller holding a
         # NARROWED within-session cap (e.g. only `Chat :leave`) would pass the
         # coarse preflight, successfully leave the old member, then FAIL the
         # `chat.join` at dispatch — stranding the role. So preflight that the
         # caller holds BOTH `chat.join` AND `chat.leave` authority (full
         # behavior/action match via `Capability.matches?/2`) BEFORE any
         # destruction. Fails closed.
         :ok <- preflight_chat_join_leave_caps(caps, session_uri, workspace_uri),
         {:ok, %URI{} = old_member_uri} <- resolve_existing_member(session_uri, role_name) do
      do_update_member_template(
        session_uri,
        workspace_uri,
        old_member_uri,
        role_name,
        new_source_template_uri,
        caller,
        caps
      )
    end
  end

  defp resolve_existing_member(%URI{} = session_uri, role_name) do
    case member_uri_for_role(session_uri, role_name) do
      %URI{} = uri -> {:ok, uri}
      nil -> {:error, {:unknown_member_role, role_name}}
    end
  end

  defp do_update_member_template(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = old_member_uri,
         role_name,
         %URI{} = new_source_template_uri,
         %URI{} = caller,
         caps
       ) do
    # PRE-DESTRUCTION — read + validate the NEW template AND capture the OLD
    # member's FULL facet map BEFORE anything is destroyed (codex round-2 P2 +
    # round-5 P2: the full facets, incl. `source_template_uri`, are needed to
    # losslessly restore the old member on rollback). Fail closed here.
    with {:ok, new_content, new_member_uri} <-
           preflight_new_template(new_source_template_uri, role_name, session_uri, workspace_uri),
         old_facets <- capture_member_facets(session_uri, old_member_uri),
         in_session_template <- Map.get(old_facets, :in_session_template, false),
         # codex round-9 P1 — check cap #2 (terminate authority on the OLD
         # member) BEFORE spawning the replacement. An unauthorized caller must
         # not even create a worker (the rollback's cleanup would itself lack
         # authority — leaking the just-spawned worker). NON-DESTRUCTIVE.
         :ok <- preflight_terminate_authority(old_member_uri, caps),
         # codex round-3 P1 #1 — REGENERATION ORDERING. A regenerate is
         # destructive (terminate the old worker). To NEVER leave a session
         # with a deleted member + no replacement on an ordinary failure
         # (PTY/config spawn failure, DB error, transient join error), we
         # SPAWN-THE-NEW-WORKER-FIRST, repoint routes, join — and ONLY THEN
         # tear down the old worker. The new worker is at a DIFFERENT URI (the
         # instance name is template-source-hashed), so the two coexist during
         # the swap. If any step before the final teardown fails, we roll back
         # the NEW worker and the OLD member is left fully intact.
         #
         # SAME-URI swaps (a re-point to a template that hashes to the SAME
         # member URI, e.g. an in-place edit of the same template) CANNOT
         # spawn-first (URI collision) — an in-place live re-materialization is
         # exactly PR-5's `reconfigure` Manage hook. PR-6 fails loud here
         # rather than attempting a fragile destroy-then-respawn-same-URI
         # (`feedback_let_it_crash_no_workarounds`; see the moduledoc overlap
         # note).
         :ok <- reject_same_uri_swap(new_member_uri, old_member_uri),
         # codex round-9 P2 — REQUIRE a FRESH spawn. `do_spawn_member` discards
         # the `fresh?` flag; if the deterministic replacement URI is already
         # live (residue from a prior failed rollback / concurrent spawn), an
         # adopted (`fresh?: false`) worker would bind the role to stale/foreign
         # config + break later lineage-gated removal. `spawn_fresh_member`
         # rejects adoption.
         {:ok, %URI{} = spawned_uri} <-
           spawn_fresh_member(
             new_content,
             content_flavor!(new_content),
             new_source_template_uri,
             role_name,
             session_uri,
             workspace_uri,
             caller
           ) do
      regenerate_finish(
        session_uri,
        old_member_uri,
        spawned_uri,
        role_name,
        new_source_template_uri,
        in_session_template,
        old_facets,
        caller,
        caps
      )
    end
  end

  # The new worker is live (spawned-first). Repoint routes old→new, join the
  # new member, then tear down the old worker LAST. Any failure before the
  # old-worker teardown rolls back the NEW worker and leaves the old member
  # intact (codex round-3 P1 #1).
  defp regenerate_finish(
         %URI{} = session_uri,
         %URI{} = old_member_uri,
         %URI{} = spawned_uri,
         role_name,
         %URI{} = new_source_template_uri,
         in_session_template,
         old_facets,
         %URI{} = caller,
         caps
       ) do
    facets = %{
      role_name: role_name,
      in_session_template: in_session_template,
      source_template_uri: new_source_template_uri
    }

    # codex round-3 P1 #2 — repoint BOTH receiver lists AND `{:from, <uri>}`
    # sender matchers (relay chains route downstream hops on the sender), so a
    # flavor swap doesn't break the chain after the swapped member.
    #
    # codex round-4 P1 — the new member shares the OLD member's `role_name`, and
    # `Chat.handle_join` rejects a duplicate role_name (`role_name_conflict/3`
    # → `{:role_name_taken, _}`). So the old member must LEAVE the session
    # members (freeing the role) BEFORE the new member joins. Leaving only
    # removes the members-map entry — the old WORKER stays alive (recoverable
    # via re-join on rollback); only the FINAL `terminate_worker` is truly
    # destructive, so it runs LAST.
    # Cap #2 (terminate authority) was already preflighted NON-DESTRUCTIVELY
    # before the spawn (codex round-8/9 P1), so the destructive
    # `terminate_worker(old)` runs ONLY AFTER the replacement join COMMITS — a
    # join failure rolls back to a STILL-ALIVE old member (the spawn-first
    # atomic guarantee holds). The COMMIT POINT is `join_member(spawned)`; every
    # step up to it is rollback-guarded.
    with :ok <- repoint_routing_rules(session_uri, old_member_uri, spawned_uri),
         :ok <- leave_member(session_uri, old_member_uri, caller, caps),
         :ok <- join_member(session_uri, spawned_uri, facets, caller, caps) do
      # POST-COMMIT — tear down the OLD worker LAST + BEST-EFFORT. Authority was
      # already proven by the preflight, so the only residual failure here is a
      # CLEANUP error (codex round-6 P2 — the old worker is scheduled for
      # destruction anyway); surface it as a warning and STILL report success,
      # so a cleanup error never rolls back the now-live replacement.
      case terminate_worker(old_member_uri, caller, caps) do
        :ok ->
          :ok

        {:error, cleanup_reason} ->
          Logger.warning(
            "update_member_template: replacement #{URI.to_string(spawned_uri)} is live + routes " <>
              "repointed (swap COMMITTED), but tearing down the old worker " <>
              "#{URI.to_string(old_member_uri)} reported #{inspect(cleanup_reason)}. The old " <>
              "worker/config may leak; the regenerate itself succeeded."
          )
      end

      {:ok, %{member_uri: spawned_uri, regenerated: true}}
    else
      {:error, reason} ->
        rollback_regenerate(
          session_uri,
          old_member_uri,
          spawned_uri,
          old_facets,
          caller,
          caps
        )

        {:error, reason}
    end
  end

  # codex round-8/9 P1+P2 — NON-DESTRUCTIVE cap #2 authority check. An
  # orchestrator may regenerate only a member it is authorized to
  # `sandbox.destroy` — the SAME boundary `remove_member`'s dispatch enforces.
  # Uses `Ezagent.Capability.matches?/2` against the FULL needed
  # `Sandbox.destroy` cap shape (kind/behavior/action/instance/workspace), NOT
  # an instance-only hand-match (codex round-9 P2): a `{:spawned_by, _}` cap of
  # the wrong kind/action/workspace must NOT authorize. `instance_match?`'s
  # `{:spawned_by, P}` branch reads the SAME `AgentLineage` the live dispatch
  # uses, so the preflight cannot diverge (`feedback_register_lookup_key_parity`).
  # Fails closed.
  # codex round-10 P1 — confirm the caller can complete BOTH halves of the
  # regenerate's session mutation: `chat.leave` (retire old) AND `chat.join`
  # (install replacement). Matched via `Capability.matches?/2` against the FULL
  # needed shapes (kind `:session`, behavior `Chat`, action `:join`/`:leave`),
  # so a NARROWED `{:within_session, S}` cap (e.g. leave-only) is rejected —
  # the SAME authority the live `chat.join` / `chat.leave` dispatches enforce.
  # Fails closed; nothing destructive runs without both.
  defp preflight_chat_join_leave_caps(caps, %URI{} = session_uri, %URI{} = workspace_uri) do
    cap_set = to_cap_set(caps)

    with :ok <- preflight_chat_action_cap(cap_set, :join, session_uri, workspace_uri) do
      preflight_chat_action_cap(cap_set, :leave, session_uri, workspace_uri)
    end
  end

  defp preflight_chat_action_cap(cap_set, action, %URI{} = session_uri, %URI{} = workspace_uri) do
    needed = %{
      kind: :session,
      behavior: Ezagent.Behavior.Chat,
      action: action,
      instance: session_uri,
      workspace_uri: workspace_uri
    }

    if Enum.any?(cap_set, &Ezagent.Capability.matches?(&1, needed)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp preflight_terminate_authority(%URI{} = old_member_uri, caps) do
    needed = %{
      kind: :agent,
      behavior: Ezagent.Behavior.Sandbox,
      action: :destroy,
      instance: old_member_uri,
      workspace_uri: Ezagent.Capability.workspace_of(old_member_uri)
    }

    authorized? =
      caps
      |> to_cap_set()
      |> Enum.any?(&Ezagent.Capability.matches?(&1, needed))

    if authorized?, do: :ok, else: {:error, :unauthorized}
  end

  # Best-effort rollback of a failed regenerate. ORDER MATTERS (codex round-5
  # P1): LEAVE the replacement member FIRST (frees the role_name), so the
  # old-member re-join below cannot conflict on the role — even if the
  # replacement had already joined before the failing step. Then repoint routes
  # BACK, terminate the NEW worker, and re-join the OLD member with its FULL
  # captured facets (codex round-5 P2 — restores the durable
  # `source_template_uri` the deleted entry would otherwise lose). The old
  # worker was only `leave`d, never terminated, in any branch reaching here, so
  # it is still alive to re-adopt.
  defp rollback_regenerate(
         %URI{} = session_uri,
         %URI{} = old_member_uri,
         %URI{} = spawned_uri,
         old_facets,
         %URI{} = caller,
         caps
       ) do
    _ = leave_member(session_uri, spawned_uri, caller, caps)
    _ = repoint_routing_rules(session_uri, spawned_uri, old_member_uri)
    _ = terminate_worker(spawned_uri, caller, caps)
    _ = join_member(session_uri, old_member_uri, old_facets, caller, caps)
    :ok
  end

  # codex round-3 P1 #1 — a SAME-URI regenerate (in-place template edit) is
  # PR-5 `reconfigure` territory; PR-6's spawn-first ordering needs distinct
  # URIs. Fail loud.
  defp reject_same_uri_swap(%URI{} = new_member_uri, %URI{} = old_member_uri) do
    if URI.to_string(new_member_uri) == URI.to_string(old_member_uri) do
      {:error, :same_member_uri_use_reconfigure}
    else
      :ok
    end
  end

  # codex P2 #1 — read + validate the NEW template content and DERIVE the
  # would-be new member URI, BEFORE any destructive step. Returns the content
  # (reused for the spawn — no second read), and the deterministic new member
  # URI (so we can detect a same-URI vs changed-URI swap). Fails closed on a
  # missing / unpopulated / flavor-less template.
  defp preflight_new_template(
         %URI{} = new_source_template_uri,
         role_name,
         %URI{} = session_uri,
         %URI{} = workspace_uri
       ) do
    with {:ok, _pid} <- ensure_template_alive(new_source_template_uri),
         {:ok, content} <- read_source_template_content(new_source_template_uri),
         {:ok, flavor} <- content_flavor(content, new_source_template_uri) do
      workspace_name =
        workspace_uri.host ||
          raise ArgumentError,
                "workspace_uri has no host (`workspace://<NAME>`) — got " <>
                  inspect(workspace_uri)

      instance_name =
        EzagentDomainInstanceMessage.spawned_member_instance_name_public(
          flavor,
          new_source_template_uri,
          role_name,
          session_uri
        )

      new_member_uri = Ezagent.URI.new!("entity://agent/#{workspace_name}/#{instance_name}")

      # codex P2 (round 2) — flavor-present is NOT enough: a template alive +
      # flavored but missing `working_directory` (or a required flavor field,
      # e.g. curl's provider) would pass this preflight, then fail validation
      # LATER inside `do_spawn_member → to_template_data/2` — AFTER the old
      # member was already terminated/left. Run the SAME flavor-validating
      # assembly NOW (against the derived member URI) so an invalid new
      # template fails closed BEFORE any destruction. The assembled data is
      # recomputed by the spawn path; here it is a pure validation pass.
      case Ezagent.Entity.AgentTemplate.to_template_data(content, new_member_uri) do
        {:ok, _data} -> {:ok, content, new_member_uri}
        {:error, reason} -> {:error, {:invalid_new_template, reason}}
      end
    end
  end

  # The flavor of an ALREADY-VALIDATED content map (preflight_new_template
  # already proved it present). Raises only on an internal contract breach.
  defp content_flavor!(content) when is_map(content) do
    Map.get(content, :flavor) || Map.get(content, "flavor")
  end

  # codex P1 #2 (rounds 1 + 3) — repoint a session's routing rules from
  # `old_member_uri` to `new_member_uri` inside ONE transaction, rewriting BOTH:
  #   * receiver lists (a rule delivering TO the member), AND
  #   * `{:from, <uri>}` sender matchers (a relay rule routing the member's
  #     OUTPUT to the next hop — `matcher_data` carries the sender URI).
  # SCOPED to THIS session's rules (`created_by == session_uri`, the PR-7/B1
  # stamp) so another session's rules are never touched. Mirrors
  # `prune_routing_rules_for/2`'s scoping + registry-reload discipline, but
  # REPLACES the URI (the member persists across a regenerate, so its rules
  # must FOLLOW it, not be deleted). A same-URI call is a no-op.
  defp repoint_routing_rules(%URI{} = _session_uri, %URI{} = old_uri, %URI{} = new_uri)
       when old_uri == new_uri,
       do: :ok

  defp repoint_routing_rules(%URI{} = session_uri, %URI{} = old_member_uri, %URI{} = new_member_uri) do
    table = EzagentDomainInstanceMessage.Routing.MentionRouting
    old_str = URI.to_string(old_member_uri)
    new_str = URI.to_string(new_member_uri)
    session_str = URI.to_string(session_uri)

    txn =
      EzagentCore.Repo.transaction(fn ->
        Ezagent.Routing.RuleStore.list(table)
        |> Enum.filter(fn rule -> rule.created_by == session_str end)
        |> Enum.reduce_while(:ok, fn rule, :ok ->
          case repoint_one_rule(rule, old_str, new_str) do
            :ok -> {:cont, :ok}
            {:error, reason} -> EzagentCore.Repo.rollback({:repoint_failed, reason})
          end
        end)
      end)

    case txn do
      {:ok, :ok} -> reload_registry(table)
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:repoint_failed, e}}
  catch
    kind, reason -> {:error, {:repoint_failed, {kind, reason}}}
  end

  # Repoint a single rule's receivers AND its `{:from, old}` sender matcher
  # (including nested combinators — `and`/`or`/`not` — codex round-4 P2). No-op
  # (`:ok`) when the rule references neither — keeps the transaction touching
  # only the affected rows.
  defp repoint_one_rule(rule, old_str, new_str) do
    receivers = rule.receivers || []
    receiver_hit? = old_str in receivers

    {new_matcher_json, matcher_hit?} = repoint_matcher_json(rule.matcher_data, old_str, new_str)

    cond do
      not receiver_hit? and not matcher_hit? ->
        :ok

      true ->
        new_receivers =
          receivers |> Enum.map(fn r -> if r == old_str, do: new_str, else: r end) |> Enum.uniq()

        with :ok <- maybe_update_receivers(rule, receiver_hit?, new_receivers),
             :ok <- maybe_update_matcher(rule, matcher_hit?, new_matcher_json) do
          :ok
        end
    end
  end

  defp maybe_update_receivers(_rule, false, _new), do: :ok

  defp maybe_update_receivers(rule, true, new_receivers),
    do: Ezagent.Routing.RuleStore.update_receivers(rule.id, new_receivers, rule.enabled)

  defp maybe_update_matcher(_rule, false, _new_json), do: :ok

  # `matcher_data` is a plain Ecto `:map` field — rewrite it in place via a
  # direct changeset (no RuleStore primitive exists for matcher mutation;
  # delete+re-add would churn the rule id + ordering identity).
  defp maybe_update_matcher(rule, true, new_matcher_json) do
    rule
    |> Ecto.Changeset.change(matcher_data: new_matcher_json)
    |> EzagentCore.Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Decode → recursively rewrite every `{:from, old_str}` leaf to
  # `{:from, new_str}` (codex round-4 P2: combinators like `and(from(old), …)`)
  # → re-encode. Returns `{new_matcher_json, changed?}`. On a non-decodable
  # matcher we leave it untouched (`{original, false}`) — never corrupt a row.
  defp repoint_matcher_json(matcher_data, old_str, new_str) do
    case Ezagent.Routing.Matcher.from_json(matcher_data) do
      {:ok, matcher} ->
        {rewritten, changed?} = rewrite_from(matcher, old_str, new_str)
        if changed?, do: {Ezagent.Routing.Matcher.to_json(rewritten), true}, else: {matcher_data, false}

      _ ->
        {matcher_data, false}
    end
  end

  # Recursive `{:from, old}` → `{:from, new}` rewrite over the typed matcher
  # AST. Returns `{new_matcher, changed?}`.
  defp rewrite_from({:from, uri_str}, old_str, new_str) when is_binary(uri_str) do
    if uri_str == old_str, do: {{:from, new_str}, true}, else: {{:from, uri_str}, false}
  end

  defp rewrite_from({:and, list}, old_str, new_str) when is_list(list),
    do: rewrite_from_list({:and, []}, list, old_str, new_str)

  defp rewrite_from({:or, list}, old_str, new_str) when is_list(list),
    do: rewrite_from_list({:or, []}, list, old_str, new_str)

  defp rewrite_from({:not, m}, old_str, new_str) do
    {sub, changed?} = rewrite_from(m, old_str, new_str)
    {{:not, sub}, changed?}
  end

  defp rewrite_from(other, _old_str, _new_str), do: {other, false}

  defp rewrite_from_list({tag, _}, list, old_str, new_str) do
    {rewritten, any?} =
      Enum.map_reduce(list, false, fn m, acc ->
        {sub, changed?} = rewrite_from(m, old_str, new_str)
        {sub, acc or changed?}
      end)

    {{tag, rewritten}, any?}
  end

  # Capture the OLD member's FULL non-authority facet map BEFORE any
  # destructive step (codex round-2 P2 + round-5 P2). The full set —
  # `role_name` / `in_session_template` / `source_template_uri` — is needed to
  # losslessly RESTORE the old member on rollback (a bare role_name re-join
  # would drop the durable `source_template_uri`, which `update_template`
  # snapshots). Returns `%{}` when the member is absent. Authority facets
  # (provenance) are deliberately excluded — `chat.join` rejects them anyway.
  defp capture_member_facets(%URI{} = session_uri, %URI{} = old_member_uri) do
    case Map.get(read_members(session_uri), old_member_uri) do
      %{} = meta ->
        meta
        |> Map.take([:role_name, :in_session_template, :source_template_uri])
        |> Map.put_new(:in_session_template, false)

      _ ->
        %{in_session_template: false}
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
               table: EzagentDomainInstanceMessage.Routing.MentionRouting,
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
    table = EzagentDomainInstanceMessage.Routing.MentionRouting
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
    table = EzagentDomainInstanceMessage.Routing.MentionRouting
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

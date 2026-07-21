defmodule Ezagent.Orchestrator.Tools.MemberTemplate do
  @moduledoc """
  `update_member_template` REGENERATION + routing-rule-repoint cluster,
  extracted VERBATIM from `Ezagent.Orchestrator.Tools` (PR-3S arch-deepening
  burn-down). Behavior-preserving relocation — no logic change.

  Holds the member-level `update_member_template` (PR-6, domain.agent): swap a
  managed member's source AgentTemplate + REGENERATE the member
  (spawn-new-then-retire-old), repointing the session's routing rules (both
  receiver lists AND `{:from, <uri>}` sender matchers) from the old member URI
  to the new one. The public `Ezagent.Orchestrator.Tools.update_member_template/3`
  stays as a thin wrapper delegating here, so external callers (the
  orchestrator MCP `run_tool` dispatch + `Tools.invoke/2`'s `apply/3` +
  tests) are unchanged.

  Shared private helpers that ALSO remain used by code left in `Tools`
  (`require_opt/2`, `preflight_within_session_cap/2`, `to_cap_set/1`,
  `ensure_template_alive/1`, `read_source_template_content/1`,
  `content_flavor/2`, `join_member/5`, `leave_member/4`, `terminate_worker/3`,
  `member_uri_for_role/2`, `read_members/1`) were made public on `Tools` and
  are called qualified from here (PR-3R pattern) — no logic duplicated across
  files. `spawn_fresh_member/8` is used ONLY by this cluster, so it was moved
  here rather than widened on `Tools`.

  See `Ezagent.Orchestrator.Tools` moduledoc for the full authority model.
  """

  require Logger

  alias Ezagent.Orchestrator.Tools

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
    with {:ok, caller} <- Tools.require_opt(opts, :caller),
         {:ok, caps} <- Tools.require_opt(opts, :caps),
         {:ok, workspace_uri} <- Tools.require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- Tools.require_opt(opts, :session_uri),
         # A regenerate is DESTRUCTIVE: it `session.leave`s
         # the old member then `chat.join`s the replacement. A caller holding a
         # narrowed within-session cap must hold BOTH exact join and leave
         # authority before any destruction.
         #
         # The shared preflight below evaluates the same complete needed-cap
         # map as Kind.Runtime: kind, behavior, action, instance, workspace,
         # and grant provenance. Keeping that predicate centralized prevents
         # an instance-only check from admitting a wrong-behavior cap before
         # teardown. Both checks happen while the old member and its routing
         # bindings are intact. A failure therefore has no compensation path
         # to run and cannot strand the role between leave and replacement.
         # This is deliberately stricter than a roster-membership admission;
         # membership admits the operation, while these caps authorize gates.
         :ok <- preflight_chat_join_leave_caps(caller, caps, session_uri),
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
    case Tools.member_uri_for_role(session_uri, role_name) do
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
         :ok <- preflight_terminate_authority(caller, old_member_uri, caps),
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
             caller,
             caps
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

    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

    member_uri = Ezagent.URI.agent(workspace_name, instance_name)

    case Ezagent.Domain.Agent.materialize_from_template(
           content,
           member_uri,
           caller,
           workspace_uri,
           caller: caller,
           caps: caps,
           source_template_uri: source_template_uri
         ) do
      {:ok, %{fresh?: true}} ->
        with :ok <-
               Ezagent.Orchestrator.Tools.SpawnAuthority.grant(
                 member_uri,
                 caller,
                 workspace_uri
               ) do
          {:ok, member_uri}
        end

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
         :ok <- Tools.leave_member(session_uri, old_member_uri, caller, caps),
         :ok <- Tools.join_member(session_uri, spawned_uri, facets, caller, caps) do
      # POST-COMMIT — tear down the OLD worker LAST + BEST-EFFORT. Authority was
      # already proven by the preflight, so the only residual failure here is a
      # CLEANUP error (codex round-6 P2 — the old worker is scheduled for
      # destruction anyway); surface it as a warning and STILL report success,
      # so a cleanup error never rolls back the now-live replacement.
      case Tools.terminate_worker(old_member_uri, caller, caps) do
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
  defp preflight_chat_join_leave_caps(holder, caps, %URI{} = session_uri) do
    with :ok <- Tools.preflight_within_session_cap(holder, caps, session_uri, :join) do
      Tools.preflight_within_session_cap(holder, caps, session_uri, :leave)
    end
  end

  defp preflight_terminate_authority(%URI{} = holder, %URI{} = old_member_uri, caps) do
    needed = %{
      kind: :agent,
      behavior: Ezagent.ActionSet.Sandbox,
      action: :destroy,
      instance: old_member_uri,
      workspace_uri: Ezagent.Capability.workspace_of(old_member_uri)
    }

    authorized? =
      Ezagent.Capability.Authorization.authorizes?(holder, Tools.to_cap_set(caps), needed)

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
    _ = Tools.leave_member(session_uri, spawned_uri, caller, caps)
    _ = repoint_routing_rules(session_uri, spawned_uri, old_member_uri)
    _ = Tools.terminate_worker(spawned_uri, caller, caps)
    _ = Tools.join_member(session_uri, old_member_uri, old_facets, caller, caps)
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
    with {:ok, _pid} <- Tools.ensure_template_alive(new_source_template_uri),
         {:ok, content} <- Tools.read_source_template_content(new_source_template_uri),
         {:ok, flavor} <- Tools.content_flavor(content, new_source_template_uri) do
      workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

      instance_name =
        EzagentDomainInstanceMessage.spawned_member_instance_name_public(
          flavor,
          new_source_template_uri,
          role_name,
          session_uri
        )

      new_member_uri = Ezagent.URI.agent(workspace_name, instance_name)

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

  defp repoint_routing_rules(
         %URI{} = session_uri,
         %URI{} = old_member_uri,
         %URI{} = new_member_uri
       ) do
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
      {:ok, :ok} -> Tools.reload_registry(table)
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

        if changed?,
          do: {Ezagent.Routing.Matcher.to_json(rewritten), true},
          else: {matcher_data, false}

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
    case Map.get(Tools.read_members(session_uri), old_member_uri) do
      %{} = meta ->
        meta
        |> Map.take([:role_name, :in_session_template, :source_template_uri])
        |> Map.put_new(:in_session_template, false)

      _ ->
        %{in_session_template: false}
    end
  end
end

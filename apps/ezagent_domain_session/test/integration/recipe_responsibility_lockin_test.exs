defmodule EzagentDomainInstanceMessage.Integration.RecipeResponsibilityLockinTest do
  @moduledoc """
  recipe-responsibility-split (2026-06-27) — the LOCK-IN invariant suite (SPEC
  §2.1, tests T1–T3 + the no-default guard).

  The SPEC's load-bearing finding: agent **recipe** (axis A — what an agent is
  built from: `Ezagent.Agent.Recipe` / `Ezagent.Agent.RecipeAttributes` / the cc-template
  `:role` / the `source_template_uri` recipe-origin facet) and session
  **responsibility** (axis B — membership `meta.role_name` + `{:role, name}`
  routing) are ALREADY separate fields with NO structural forcing of
  `role_name == recipe-name`. This suite converts that incidental separation into
  a guarded contract: each test fails if a future change re-forces `role_name`
  from the recipe.

  Per the SPEC's codex MED, each test asserts the A representation its spawn path
  actually writes:

    * a **cc-template spawn** (`Tools.add_managed_member/4`, T1) carries A as the
      member's `source_template_uri` recipe-origin facet + the template flavor —
      it does NOT write the RF-7 `RecipeAttributes` marker, so we never assert
      that marker over a template-spawned member;
    * the seed **declared-member** representation (T3) carries A as the
      `source_template_uri` recipe-origin facet (the exact facet the
      `application.ex` default-template seed declares alongside `role_name`).

  No production change rides this PR except the two no-default doc-comments
  (`membership.ex` do_join + `application.ex` seed). The symbol rename
  `Ezagent.Role`/`RoleRegistry` → `Ezagent.Agent.Recipe`/`RecipeRegistry` was
  applied in #127 (this rename lands the A-axis struct/module on `Recipe*`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{
    AgentFlavorAttributes,
    Agent.RecipeAttributes,
    Capability,
    Invocation,
    KindRegistry
  }

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Orchestrator.Tools
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateTeam

  @workspace_uri URI.new!("workspace://system")

  defp uniq, do: System.unique_integer([:positive])

  # ── slice / meta readers ───────────────────────────────────────────────

  defp chat_slice(%URI{} = session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  defp members_meta(%URI{} = session_uri), do: chat_slice(session_uri).members

  defp wait_until(fun, retries \\ 200) do
    case fun.() do
      false when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end

  defp await_member_meta(session_uri, member_uri, pred) do
    meta =
      wait_until(fn ->
        m = members_meta(session_uri)[member_uri]
        if is_map(m) and pred.(m), do: m, else: false
      end)

    assert is_map(meta),
           "expected member #{URI.to_string(member_uri)} meta to satisfy predicate; " <>
             "members=#{inspect(Map.keys(members_meta(session_uri)))}"

    meta
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp terminate_child(sup, %URI{} = uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: DynamicSupervisor.terminate_child(sup, pid)
      :error -> :ok
    end
  end

  # A plainly-spawned Session Kind (no template materialization) — the same
  # fixture shape the orchestrator-tools integration suite uses.
  defp plain_session(prefix) do
    session_uri = Ezagent.URI.session("system", "generic", "#{prefix}-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)

    on_exit(fn ->
      terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, session_uri)
    end)

    session_uri
  end

  # A live member registered in KindRegistry so `chat.join` resolves a pid to
  # monitor. `kind` selects an `entity://…/agent/…` host (skips the user-only
  # branches in do_join) or an `entity://…/user/…` principal (axis-B is
  # cross-principal — a USER can hold a responsibility).
  defp register_member(kind) when kind in [:agent, :user] do
    uri = URI.new!("entity://team-alpha/#{kind}/#{kind}-#{uniq()}")
    test_pid = self()

    pid =
      spawn(fn ->
        :ok = KindRegistry.put_new(uri)
        send(test_pid, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 1_000
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    uri
  end

  defp join_call(session_uri, member_uri, facets) do
    Invocation.dispatch(%Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: Map.put(facets, :member, member_uri),
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # Persist a minimal cc-flavor AgentTemplate Kind to spawn a member from. The
  # template URI IS the agent RECIPE origin (axis A) — its last path segment
  # ("cc-coder-<n>") is the recipe's identity, distinct from any session
  # responsibility a member spawned from it may later hold. (We do NOT stamp a
  # content `:role`: the cc template only accepts known recipe names there, and
  # the recipe-origin facet `source_template_uri` is the A representation this
  # spawn path actually writes — SPEC codex MED.)
  defp seed_agent_template(n) do
    uri = Ezagent.URI.new!("template://system/agent/cc-coder-#{n}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(uri)}?action=template.write"),
        mode: :call,
        args: %{
          content: %{
            flavor: "cc",
            project_cwd: "/tmp",
            default_caps: [],
            created_by: User.admin_uri(),
            created_at: ~U[2026-06-01 00:00:00Z]
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Capability.admin_genesis_cap()]),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn -> terminate_child(EzagentDomainInstanceMessage.AgentTemplateSupervisor, uri) end)
    uri
  end

  defp orchestrated_session(prefix) do
    session_uri = plain_session(prefix)

    orchestrator_uri = Ezagent.URI.new!("entity://system/agent/cc_orch-#{uniq()}")
    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
    on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

    caps =
      MapSet.new([
        %Capability{
          kind: :session,
          behavior: :any,
          action: :any,
          instance: {:within_session, session_uri},
          workspace_uri: @workspace_uri,
          granted_by: User.admin_uri(),
          granted_at: DateTime.utc_now()
        },
        %Capability{
          kind: :agent,
          behavior: :any,
          action: :any,
          instance: {:spawned_by, orchestrator_uri},
          workspace_uri: @workspace_uri,
          granted_by: User.admin_uri(),
          granted_at: DateTime.utc_now()
        }
      ])

    mcp = [
      caller: orchestrator_uri,
      caps: caps,
      session_uri: session_uri,
      workspace_uri: @workspace_uri,
      owner: orchestrator_uri,
      parent_template_uri: nil
    ]

    {mcp, session_uri}
  end

  # =======================================================================
  # T1 — recipe-name ≠ session role_name is admissible (cc-template spawn).
  # =======================================================================

  describe "T1 — a recipe and a session role_name can differ (SPEC §2.1)" do
    test "a member spawned from the cc-coder recipe holds session role_name 'reviewer' — both resolve, independently" do
      n = uniq()
      src = seed_agent_template(n)
      recipe_name = src.path |> to_string() |> String.split("/", trim: true) |> List.last()
      {mcp, session_uri} = orchestrated_session("rrlock-t1")

      assert {:ok, member_uri} = Tools.add_managed_member(src, "reviewer", true, mcp)
      on_exit(fn -> terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, member_uri) end)

      members = members_meta(session_uri)

      # ── axis B (responsibility) drives routing: role_name "reviewer" ──────
      assert SessionBehavior.role_name_to_uri(members, "reviewer") == member_uri
      assert members[member_uri].role_name == "reviewer"

      # ── axis A (recipe) is the recipe-origin facet `source_template_uri` +
      #    the template's flavor — the A representation THIS spawn path writes
      #    (SPEC codex MED). The recipe identity is NOT renamed to "reviewer". ─
      assert members[member_uri].source_template_uri == src
      assert {:ok, content} = Tools.read_source_template_content(src)
      assert Tools.content_flavor(content, src) == {:ok, "cc"}

      # ── the two axes are different namespaces, neither derived from the other.
      refute members[member_uri].role_name == recipe_name

      assert SessionBehavior.role_name_to_uri(members, recipe_name) == nil,
             "the recipe identity #{inspect(recipe_name)} must NOT be a session responsibility holder"

      # ── the join did NOT pollute the recipe (RF-7) marker from role_name.
      #    A cc-template spawn writes no marker at all, so it is :none — but
      #    crucially it is never the responsibility label "reviewer". ─────────
      refute RecipeAttributes.fetch(member_uri) == {:ok, "reviewer"}
    end
  end

  # =======================================================================
  # T2 — a recipe-less USER principal can hold a session role_name (SPEC §2.1).
  # =======================================================================

  describe "T2 — a recipe-less user holds a responsibility (SPEC §2.1)" do
    test "a user member carries role_name 'reviewer' and resolves via {:role,_}, owning no recipe" do
      session_uri = plain_session("rrlock-t2")
      user_uri = register_member(:user)

      assert {:ok, _} = join_call(session_uri, user_uri, %{role_name: "reviewer"})

      meta = await_member_meta(session_uri, user_uri, &(&1[:role_name] == "reviewer"))
      assert meta.role_name == "reviewer"

      # B is cross-principal: a USER resolves through the SAME role resolver
      # `{:role, name}` routing uses (`Members.role_name_to_uri/2`).
      assert SessionBehavior.role_name_to_uri(members_meta(session_uri), "reviewer") == user_uri

      # …and it owns NO recipe (axis A is agent-build-time only).
      assert RecipeAttributes.fetch(user_uri) == :none
      assert AgentFlavorAttributes.get(user_uri) == :none
    end
  end

  # =======================================================================
  # T3 — the orchestrator's session role_name is independent of its recipe
  #      (SPEC §2.1 / the §1.3 conflation point #3 lock-in).
  # =======================================================================

  describe "T3 — orchestrator role_name is independent of its recipe (SPEC §2.1)" do
    test "the orchestrator recipe can hold session role_name 'lead' — recipe 'orchestrator' is not structurally bound to it" do
      session_uri = plain_session("rrlock-t3")
      member_uri = register_member(:agent)

      # The §1.3(3) seed declares the orchestrator as
      #   %{role_name: "orchestrator", source_template_uri: <cc-orchestrator>, …}
      # — two independent fields coinciding on a literal by convention. Here we
      # join the SAME orchestrator recipe (source_template_uri) under a DIFFERENT
      # session role_name "lead", proving the coincidence is not a forcing.
      orchestrator_recipe = URI.new!("template://system/agent/cc-orchestrator")

      assert {:ok, _} =
               join_call(session_uri, member_uri, %{
                 role_name: "lead",
                 source_template_uri: orchestrator_recipe,
                 in_session_template: true
               })

      meta = await_member_meta(session_uri, member_uri, &(&1[:role_name] == "lead"))

      # axis B: routing addresses it as {:role, "lead"} …
      assert meta.role_name == "lead"
      assert SessionBehavior.role_name_to_uri(members_meta(session_uri), "lead") == member_uri

      # axis A: the recipe origin is the cc-orchestrator recipe, untouched …
      assert meta.source_template_uri == orchestrator_recipe
      assert String.ends_with?(to_string(orchestrator_recipe.path), "cc-orchestrator")

      # …and the recipe literal "orchestrator" is NOT a responsibility holder.
      refute meta.role_name == "orchestrator"
      assert SessionBehavior.role_name_to_uri(members_meta(session_uri), "orchestrator") == nil
    end
  end

  # =======================================================================
  # No-default guard — a join WITHOUT role_name does NOT inherit the recipe
  # name (SPEC §2.2 / OQ-1; the decision pinned at the membership.ex do_join
  # doc-comment and the application.ex seed doc-comment).
  # =======================================================================

  describe "no recipe → role_name default (SPEC §2.2 / OQ-1)" do
    test "a recipe-bearing member joined WITHOUT a role_name facet has NO role_name (not derived from the recipe)" do
      session_uri = plain_session("rrlock-nodefault")
      member_uri = register_member(:agent)

      # The member carries a recipe LINK (source_template_uri) — the recipe is
      # present — but the join supplies NO :role_name facet.
      recipe = URI.new!("template://system/agent/cc-coder")

      assert {:ok, _} =
               join_call(session_uri, member_uri, %{
                 source_template_uri: recipe,
                 in_session_template: true
               })

      meta = await_member_meta(session_uri, member_uri, &(&1[:online] == true))

      # `put_member_facets/2` skips the nil :role_name — the member ends with NO
      # role_name. It is NOT silently set to the recipe name ("cc-coder").
      refute Map.has_key?(meta, :role_name)
      assert SessionBehavior.role_name_to_uri(members_meta(session_uri), "cc-coder") == nil
      assert SessionBehavior.role_name_to_uri(members_meta(session_uri), "coder") == nil
    end

    test "the role_name-absent instance-name path falls back to the source-TEMPLATE segment, never the recipe" do
      session_uri = plain_session("rrlock-instname")
      src = URI.new!("template://system/agent/cc-coder-#{uniq()}")
      segment = src.path |> to_string() |> String.split("/", trim: true) |> List.last()

      # role_name = nil → the slot is derived from the source-template path
      # segment (SPEC §0.2 / template_team.ex spawned_member_instance_name), NOT
      # from any recipe `:role`.
      absent = TemplateTeam.spawned_member_instance_name_public("cc", src, nil, session_uri)

      present =
        TemplateTeam.spawned_member_instance_name_public("cc", src, "reviewer", session_uri)

      assert String.contains?(absent, segment),
             "role_name-absent slot must fall back to the template path segment #{inspect(segment)}; got #{inspect(absent)}"

      assert String.contains?(present, "reviewer"),
             "an explicit role_name must drive the slot; got #{inspect(present)}"

      refute absent == present
    end
  end
end

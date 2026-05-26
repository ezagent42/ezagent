defmodule EzagentDomainChat.Integration.SessionAutoJoinTest do
  @moduledoc """
  Session member auto-join (Allen 2026-05-26) — regression coverage for
  the gap where the MemberPanel rendered empty even after a session was
  opened or an orchestrator team had been spawned.

  Three layers covered:

  1. **Creator auto-join via create_session/3** (legacy) — already
     worked; locked here so a refactor doesn't regress it.

  2. **Orchestrator + workers auto-join via Session.spawn_from_template/2**
     (Step 8 of the reconciler, added 2026-05-26) — the orchestrator
     URI returned by `ensure_orchestrator` AND every successfully-
     reconciled worker URI appear in the Session's `chat.members`
     slice WITHOUT the operator clicking Invite. This is the
     "orchestrator missing from MemberPanel" half of the gap.

  3. **`:join` idempotency** — re-dispatching `chat.join` for an
     already-online member does NOT stack monitor refs. The session's
     `slice.monitors` map size is bounded by `Map.size(members)` for
     online members.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, Behavior, Capability, KindRegistry}
  alias Ezagent.Entity.{Session, SessionTemplate, User}

  # --- a no-PTY test Template Class --------------------------------------

  defmodule TestFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "session-auto-join.test.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
      agent_uri = URI.parse(uri_str)

      case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end

  # --- helpers (mirror generator_test.exs's pattern) ---------------------

  defp uniq, do: System.unique_integer([:positive])

  defp register_test_flavor do
    flavor = "ajtest#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: TestFlavorClass
      })

    flavor
  end

  defp agent_template_content(flavor, name) do
    %{
      name: name,
      description: "worker #{name}",
      flavor: flavor,
      working_directory: "/tmp/session-auto-join-test",
      claude_config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-26 00:00:00Z]
    }
  end

  defp create_agent_template(uri, content) do
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})
    :ok
  end

  defp dispatch(uri, action, args) do
    target = URI.parse("#{URI.to_string(uri)}?action=#{action}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp create_session_template(name, agent_slots, routing_rules) do
    content = %{
      name: name,
      description: "auto-join test team #{name}",
      agent_slots: agent_slots,
      routing_rules: routing_rules,
      orchestrator_template_uri: URI.parse("template://agent/system/cc-orchestrator"),
      default_workspace_uri: URI.parse("workspace://team-alpha"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-26 00:00:00Z]
    }

    {:ok, uri} = SessionTemplate.persist_version(content, "team-alpha")
    uri
  end

  defp spawn_owner(uri, caps) do
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: MapSet.new(caps)})
    :ok
  end

  defp template_cap(kind, workspace_uri) do
    %Capability{
      kind: kind,
      behavior: Behavior.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp session_members(%URI{} = session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)

    %{state: %{chat: slice}} = :sys.get_state(pid)
    {Map.keys(slice.members), slice.monitors, slice}
  end

  defp wait_until(fun, retries \\ 100) do
    case fun.() do
      false when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end

  @workspace_uri URI.new!("workspace://team-alpha")

  # ----------------------------------------------------------------------
  # Layer 1 — legacy creator auto-join via create_session/3
  # ----------------------------------------------------------------------

  describe "creator auto-join (legacy via create_session/3)" do
    test "admin appears in chat.members after create_session" do
      short = "ajs-creator-#{uniq()}"
      admin = User.admin_uri()

      {:ok, session_uri, _meta} =
        EzagentDomainChat.create_session(short, admin, template_name: "default")

      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               Enum.any?(members, &(URI.to_string(&1) == URI.to_string(admin)))
             end),
             "admin must appear in chat.members WITHOUT a manual Invite"
    end
  end

  # ----------------------------------------------------------------------
  # Layer 2 — orchestrator + worker auto-join via spawn_from_template/2
  # ----------------------------------------------------------------------

  describe "orchestrator + worker auto-join (Step 8 of reconciler)" do
    setup do
      flavor = register_test_flavor()

      backend_uri = URI.new!("template://agent/team-alpha/aj-backend-#{uniq()}")
      frontend_uri = URI.new!("template://agent/team-alpha/aj-frontend-#{uniq()}")

      :ok = create_agent_template(backend_uri, agent_template_content(flavor, "backend"))
      :ok = create_agent_template(frontend_uri, agent_template_content(flavor, "frontend"))

      st_uri =
        create_session_template(
          "aj-team-#{uniq()}",
          [{"backend", backend_uri}, {"frontend", frontend_uri}],
          []
        )

      owner_uri = URI.parse("entity://user/team-alpha/aj-owner-#{uniq()}")

      :ok =
        spawn_owner(owner_uri, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      %{st_uri: st_uri, owner_uri: owner_uri}
    end

    test "orchestrator URI lands in chat.members WITHOUT manual Invite", %{
      st_uri: st_uri,
      owner_uri: owner_uri
    } do
      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               Enum.any?(members, &(URI.to_string(&1) == URI.to_string(orch_uri)))
             end),
             "orchestrator #{URI.to_string(orch_uri)} must appear in " <>
               "#{URI.to_string(session_uri)} chat.members WITHOUT clicking Invite"
    end

    test "every reconciled worker URI lands in chat.members", %{
      st_uri: st_uri,
      owner_uri: owner_uri
    } do
      {:ok, %{session_uri: session_uri, slots: slots}} =
        Session.spawn_from_template(st_uri, owner_uri)

      worker_uris =
        slots
        |> Enum.map(fn {_slot, %URI{} = worker_uri} -> URI.to_string(worker_uri) end)
        |> Enum.sort()

      assert worker_uris != [], "test setup must produce ≥1 worker"

      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               member_strs = Enum.map(members, &URI.to_string/1)

               Enum.all?(worker_uris, fn w -> w in member_strs end)
             end),
             "every reconciled worker (#{inspect(worker_uris)}) must appear in chat.members"
    end

    test "re-running spawn_from_template — already-converged members do NOT stack monitor refs",
         %{st_uri: st_uri, owner_uri: owner_uri} do
      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      # Wait for the first batch of joins to settle.
      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               # orchestrator + 2 workers = 3
               length(members) >= 3
             end)

      # Capture per-member monitor counts BEFORE the reconcile re-run.
      # The orchestrator URI is deterministic (`derive_orchestrator_uri`)
      # so it MUST stay present across re-runs at exactly one monitor.
      {members_before, monitors_before, _slice} = session_members(session_uri)
      n_orch_monitors_before = count_monitors_for(monitors_before, orch_uri)

      assert n_orch_monitors_before == 1,
             "before reconcile re-run, orchestrator must hold exactly 1 monitor " <>
               "(got #{n_orch_monitors_before})"

      members_before_strs = Enum.map(members_before, &URI.to_string/1) |> Enum.sort()

      # Idempotent reconcile — re-running must converge to the SAME
      # session URI. The orchestrator URI is deterministic, so the
      # `Behavior.Chat.invoke(:join)` idempotency short-circuit must
      # fire and NOT stack a fresh monitor. (Worker URIs may differ
      # because the test flavor's template_class produces a new
      # `entity://agent/<ws>/<flavor>_<name>` URI on each instantiate
      # — that's a slot-reconcile idempotency limitation orthogonal
      # to chat.members tracking.)
      {:ok, %{session_uri: ^session_uri, orchestrator_uri: ^orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      # Give the casts a chance to land + the idempotency short-
      # circuit to fire.
      Process.sleep(150)

      {_members_after, monitors_after, _slice} = session_members(session_uri)
      n_orch_monitors_after = count_monitors_for(monitors_after, orch_uri)

      assert n_orch_monitors_after == 1,
             "orchestrator must still hold exactly 1 monitor after a second " <>
               "reconcile pass (got #{n_orch_monitors_after}) — Behavior.Chat.invoke(:join) " <>
               "idempotency regression in slice.monitors"

      # Each member URI that EXISTED before must still hold exactly 1
      # monitor afterwards — no stacking on the idempotent path.
      for member_str <- members_before_strs do
        member_uri = URI.parse(member_str)
        n = count_monitors_for(monitors_after, member_uri)

        assert n == 1,
               "pre-existing member #{member_str} must hold exactly 1 monitor " <>
                 "after idempotent reconcile (got #{n})"
      end
    end
  end

  # Count monitor refs in `monitors` that point at `member_uri`.
  defp count_monitors_for(monitors, %URI{} = member_uri) do
    target = URI.to_string(member_uri)
    Enum.count(monitors, fn {_ref, uri} -> URI.to_string(uri) == target end)
  end

  # ----------------------------------------------------------------------
  # Layer 3 — `:join` invoke idempotency at the slice level
  # ----------------------------------------------------------------------

  describe ":join idempotency (Behavior.Chat)" do
    # Codex r1 HIGH-1 (2026-05-26) — strict pid-match short-circuit
    # regression test. The short-circuit MUST verify the held monitor
    # ref is for the SAME pid KindRegistry currently resolves the URI
    # to; otherwise the dead-old-pid + fresh-new-pid + stale-:DOWN
    # window causes the live member to be marked offline.
    test "short-circuit fires only when the held monitor ref is for the CURRENT pid" do
      short = "ajs-pid-#{uniq()}"
      admin = User.admin_uri()

      {:ok, session_uri, _meta} =
        EzagentDomainChat.create_session(short, admin, template_name: "default")

      # Wait for the creator-auto-join cast to land.
      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               Enum.any?(members, &(URI.to_string(&1) == URI.to_string(admin)))
             end)

      # The admin Kind's current pid + the session's current monitor
      # ref for admin.
      {:ok, admin_pid_before} = KindRegistry.lookup(admin)

      {_members, monitors_before, _slice} = session_members(session_uri)

      # Check that `:monitored_by` on admin includes the session pid.
      {:ok, session_pid} = KindRegistry.lookup(session_uri)

      {:monitored_by, monitored_by} = Process.info(admin_pid_before, :monitored_by)

      assert session_pid in monitored_by,
             "Session must hold a monitor on the admin pid (the structural " <>
               "anchor for the chat.join idempotency short-circuit)"

      # Repeated chat.join with the SAME admin pid — must NOT stack
      # monitors AND must NOT install a fresh ref (the existing one
      # is for the current pid).
      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      :ok =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :cast,
          args: %{member: admin},
          ctx: %{
            caller: Ezagent.SystemPrincipal.uri("session-internal"),
            caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
            reply: :ignore
          }
        })

      Process.sleep(100)

      {_members_after, monitors_after, _slice} = session_members(session_uri)

      # Same ref + same count — full short-circuit fired.
      assert monitors_after == monitors_before,
             "short-circuit must leave slice.monitors UNCHANGED for same-pid rejoin " <>
               "(pre #{inspect(monitors_before)}, post #{inspect(monitors_after)})"
    end

    test "re-dispatching chat.join for the same member does NOT stack monitors" do
      short = "ajs-idem-#{uniq()}"
      admin = User.admin_uri()

      {:ok, session_uri, _meta} =
        EzagentDomainChat.create_session(short, admin, template_name: "default")

      # Wait for the creator-auto-join cast to land.
      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               Enum.any?(members, &(URI.to_string(&1) == URI.to_string(admin)))
             end)

      {_members_before, monitors_before, _slice} = session_members(session_uri)
      ref_count_before = map_size(monitors_before)

      # Dispatch chat.join 5 more times — every one should be a no-op
      # at the slice level (online + monitor alive → short-circuit).
      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      for _ <- 1..5 do
        :ok =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :cast,
            args: %{member: admin},
            ctx: %{
              caller: Ezagent.SystemPrincipal.uri("session-internal"),
              caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
              reply: :ignore
            }
          })
      end

      # Let the casts drain.
      Process.sleep(150)

      {_members_after, monitors_after, _slice} = session_members(session_uri)

      assert map_size(monitors_after) == ref_count_before,
             "5 repeated chat.join casts must NOT stack monitor refs (was " <>
               "#{ref_count_before}, now #{map_size(monitors_after)}) — " <>
               "Behavior.Chat.invoke(:join) idempotency regression"
    end
  end
end

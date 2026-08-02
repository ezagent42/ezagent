defmodule EzagentPluginHello.Integration.HelloWorkspaceIsolationTest do
  @moduledoc """
  hello-A fail-before / pass-after: the 官网 workspace de-hardcode unmutes the
  greeter by making `session-ws == owner-ws == users-ws == ezagent`, so
  `do_workspace_isolation_check` (`Ezagent.Kind.Runtime`) passes at `ws_equal?`
  with ZERO cap-machinery change.

  LAYERED ACCEPTANCE (spec Addendum should-fix #2): hello-A cures the
  **anonymous visitor** path (the 官网's real audience) — the anon's born-with
  `join_cap` is issued under system-admin authority, workspace-independent, and
  verifies in `ezagent`. The **logged-in ezagent member** join-cap grant
  (`do_grant_join_cap`) is #195 Phase M, OUT of scope — so the fail-before leg
  below uses an ezagent principal with an EXPLICITLY issued cap (proving the
  denial is the workspace boundary, not missing caps), and the pass-after leg
  drives the ANON path.

  Fail-before (the pre-fix shape — 官网 pinned in `system`, users in `ezagent`):
  an ezagent principal's genuine `session.send` (cast, the exact dispatch the
  SessionFeedChannel makes) trips the isolation check — observed via the
  `[:ezagent, :workspace, :denied]` telemetry event the runtime fires — and the
  call-mode `session.join` returns `{:error, :cross_workspace_denied}`.

  Pass-after: `ezagent-official` in `ezagent` owned by an ezagent principal —
  the anon is admitted through the REAL web ingress primitive
  (`AnonAdmission.admit_anonymous_participant/1`: mint into `ezagent` → spawn →
  bind → join with the born-with join_cap), and the `{always} -> front-desk`
  relay fires through the genuine runtime receive primitive
  (`Delivery.dispatch_receive_call/3`, the `hello_greeter_relay_repro_test`
  pattern). Keyless by design: the acceptable
  downstream stop is the concierge's `{:no_api_key, "deepseek"}` PAST the
  resolver — that proves the workspace gate opened.
  """
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ezagent.ActionSet.Session.Delivery
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Entity.User
  alias Ezagent.{Invocation, KindRegistry, Message, Workspace}
  alias EzagentPluginHello.App
  alias EzagentPluginHello.Application, as: HelloApp

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kanban)

    Enum.each(HelloApp.roles(), fn recipe ->
      {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    # Stale-Kind hygiene: sibling tests in this BEAM (official_site_seed_test)
    # provision the SAME workspace/user/session names; their DB rows roll back
    # with the sandbox but the live Kind processes (and the signed caps/keys in
    # their state) survive, which surfaces as `:invalid_cap_signature` /
    # `:not_found` in this module's cap-checked flows. Terminate them so every
    # create below is a FRESH spawn consistent with the current transaction.
    home = EzagentPluginHello.home_workspace()

    Enum.each(
      [
        Ezagent.URI.session(home, :hello, "ezagent-official"),
        Ezagent.URI.session("system", :hello, "web"),
        Ezagent.URI.entity(home, :user, "lin_yilun"),
        Ezagent.URI.workspace(home),
        Ezagent.URI.workspace("system")
      ],
      &terminate/1
    )

    # The relay must resolve WITHOUT any real LLM key; clear it so a pass proves
    # the resolver+cap path, not an ambient credential.
    prev_key = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")
    on_exit(fn -> if prev_key, do: System.put_env("DEEPSEEK_API_KEY", prev_key) end)

    :ok
  end

  test "FAIL-BEFORE: an ezagent principal sending to a system-pinned 官网 is cross-workspace denied" do
    ensure_workspace("system")
    {:ok, session_uri, _front_desk} = App.ensure_app("system", "web")

    member = Ezagent.URI.entity("ezagent", :user, "member-#{System.unique_integer([:positive])}")

    # #195: the member must be a CURRENT principal (durable held caps) or the
    # dispatch is denied `:holder_revoked` at the principal gate BEFORE the
    # workspace-isolation check the test targets. Establish currency the
    # non-spawning durable way — a real user row carrying its own self-license
    # (`Users.create_read_only`) so `IdentityCaps.load(member) ≠ []`.
    {:ok, _} = Ezagent.Users.create_read_only(member, [self_license_cap!(member)])

    # The member HOLDS the caps (issued under admin authority — modeling a
    # granted member), so authz passes and the denial that fires is the
    # WORKSPACE BOUNDARY, not a missing cap.
    send_target = Ezagent.URI.with_action(session_uri, :session, :send)
    join_target = Ezagent.URI.with_action(session_uri, :session, :join)

    {:ok, send_cap} =
      Ezagent.Cap.issue_for_action({:admin, User.admin_uri()}, member, send_target)

    {:ok, join_cap} =
      Ezagent.Cap.issue_for_action({:admin, User.admin_uri()}, member, join_target)

    # (1) The genuine SEND path (cast — the exact dispatch SessionFeedChannel's
    # `dispatch_post` makes). The denial is observed via the telemetry event
    # `do_workspace_isolation_check` fires.
    handler_id = "ws-denied-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:ezagent, :workspace, :denied],
      fn _event, _measurements, meta, pid -> send(pid, {:ws_denied, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    msg = Message.new(member, %{text: "hello greeter", attachments: []})

    _ =
      Invocation.dispatch(%Invocation{
        target: send_target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: member,
          authenticated_principal: member,
          caps: MapSet.new([send_cap]),
          reply: :ignore
        },
        origin: :authenticated_external
      })

    assert_receive {:ws_denied, meta}, 5_000
    assert meta.caller_workspace == Ezagent.URI.workspace("ezagent")
    assert meta.target_workspace == Ezagent.URI.workspace("system")

    # (2) The exact atom, synchronously, on the call-mode join the member
    # genuinely uses (SessionFeedChannel.dispatch_join).
    assert {:error, :cross_workspace_denied} =
             Invocation.dispatch(%Invocation{
               target: join_target,
               mode: :call,
               args: %{member: member},
               ctx: %{
                 caller: member,
                 authenticated_principal: member,
                 caps: MapSet.new([join_cap]),
                 reply: :ignore
               },
               origin: :authenticated_external
             })
  end

  test "PASS-AFTER: ezagent-official in ezagent — the ANON visitor path joins and the greeter relay fires" do
    home = EzagentPluginHello.home_workspace()
    owner = Ezagent.URI.entity(home, :user, "lin_yilun")
    # The owner must be a REAL user (the member-cap grant flow absorbs caps
    # into it) — on deploys lin_yilun exists; create the row here the same way.
    {:ok, _} = Ezagent.Users.create(owner, nil, [], email_verified: false)
    ensure_workspace(home, owner)

    {:ok, session_uri, front_desk_uri} = App.ensure_app(home, "ezagent-official", owner: owner)

    # The session is owned by the ezagent principal, NOT the system admin.
    assert {:ok, ^owner} = Ezagent.Entity.Session.owner(session_uri)

    # The REAL anon ingress primitive (the web `/socialware/chat` chokepoint):
    # mint → spawn the anon principal → bind → join AS the anon with its
    # born-with join_cap threaded. Pre-fix the join inside this admission was
    # exactly what a system-pinned 官网 denied; a successful admission IS the
    # join succeeding end-to-end.
    assert {:ok, %{anon_uri: anon_uri, source: :minted}} =
             Ezagent.Socialware.AnonAdmission.admit_anonymous_participant(session_uri)

    # The anon minted INTO the session's workspace — `caller_ws == target_ws`.
    assert Ezagent.Capability.workspace_of(anon_uri) == Ezagent.URI.workspace(home)

    # The `{always} -> front-desk` relay fires for the anon's message, driven
    # through the genuine runtime receive primitive (the greeter-relay-repro
    # pattern). Keyless: the acceptable stop is `{:no_api_key, "deepseek"}`
    # PAST the resolver — a crash or a workspace denial is NOT acceptable.
    _ = Ezagent.Domain.Agent.ensure_deliverable(front_desk_uri)
    {:ok, front_desk_pid} = KindRegistry.lookup(URI.to_string(front_desk_uri))

    msg = Message.new(anon_uri, %{text: "hello greeter", attachments: []})

    log =
      capture_log(fn ->
        _ = Delivery.dispatch_receive_call(front_desk_uri, msg, session_uri)
        drain_mailbox(front_desk_pid)
        # The `{always} -> front-desk` relay dispatches to the member in a
        # supervised Task (`Router` → `EzagentPluginHello.TaskSupervisor`) that
        # does a Repo-touching `Cap.issue`. Await it INSIDE the sandbox so its
        # DB work (and its log) finishes within the test — otherwise the Task
        # outlives the DataCase owner and races teardown (a pre-existing
        # `DBConnection.OwnershipError`, unrelated to the cap-fixture fix).
        await_relay_tasks()
      end)

    refute log =~ "cross_workspace_denied",
           "the workspace gate still denies the anon relay:\n#{log}"

    refute log =~ "handle_receive/2 crashed",
           "Agent.Receive.handle_receive/2 crashed during the anon relay:\n#{log}"

    assert Process.alive?(front_desk_pid)
  end

  defp ensure_workspace(name, created_by \\ nil) do
    attrs = if created_by, do: %{created_by: created_by}, else: %{}

    # #195: `Workspace.create` on an ALREADY-EXISTING workspace poisons the
    # sandbox transaction — its `create_workspace_record` `Repo.transaction`
    # wrapper (added in #195) does not recover the unique-constraint INSERT
    # violation inside the sandbox's outer transaction, so the recovery
    # `Repo.get_by` aborts. "system" is boot-seeded (and siblings re-provision
    # the home workspace), so pre-check existence and skip the re-create. This
    # is test SETUP; the cross-workspace denial the test proves is unaffected.
    unless Ezagent.Workspace.Store.get_by_name(name) do
      case Workspace.create(name, attrs) do
        {:ok, _pid} -> :ok
        {:error, :workspace_exists} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    # The owner must be a real MEMBER (pre-spawns their user Kind so the
    # cap-grant/absorb flow has a live actor). `add_member` performs no
    # workspace re-INSERT, so it is safe on an already-existing workspace.
    if created_by do
      case Workspace.add_member(name, created_by) do
        :ok -> :ok
        {:error, _} -> :ok
      end
    end

    :ok
  end

  # Three synchronous barriers (see HelloGreeterRelayReproTest): FIFO ordering
  # guarantees the :receive + deferred :hello_sync_result casts ran before this
  # returns — no sleeps, no flake.
  defp drain_mailbox(pid) do
    Enum.each(1..3, fn _ -> _ = :sys.get_state(pid) end)
  end

  # Wait for the relay's fire-and-forget supervised Tasks (member dispatch) to
  # drain so their Repo work completes before the sandbox owner is reclaimed.
  # Monitor each live child to completion — no sleeps.
  defp await_relay_tasks(timeout \\ 2_000) do
    EzagentPluginHello.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        timeout -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  defp terminate(%URI{} = uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      _ -> :ok
    end
  end
end

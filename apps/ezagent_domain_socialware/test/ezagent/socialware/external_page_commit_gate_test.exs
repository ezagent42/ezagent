defmodule Ezagent.Socialware.ExternalPageCommitGateTest do
  @moduledoc """
  P2.5a — the external PAGE is commit-gated: it renders from the latest COMMITTED
  settlement's surface version (never the live approved-but-uncommitted slice). A
  pending settlement does not expose a page; dropping the {:external_delivery}
  wake-up still delivers via the durable snapshot; a committed page survives a
  stopped session (cold read) and a missing WorkspaceRegistry binding (cold auth).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.ExternalFeed

  @owner Ezagent.URI.entity(:team_alpha, :user, "p2-5a-owner")

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "p2-5a-#{System.unique_integer([:positive])}")
  end

  defp agent_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{origin: :trusted_internal,
      target: target(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_until(fun, attempts - 1)
        )
  end

  defp spawn_session do
    uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(uri))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: uri,
        owner_uri: @owner,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  # The external read is authorized by LIVE membership (the session owner/member),
  # not an identity-less token. The page projection itself is auth-agnostic; only
  # the AUTH carrier changed from a token to a principal.
  defp test_caller(_session_uri), do: @owner

  # open -> dispatch -> deliver(page) -> compose; returns {turn_id, version}.
  # Does NOT settle (caller chooses approve-only vs full settle).
  defp compose_page(uri, page_tree) do
    {:ok, %{turn_id: turn_id}} =
      dispatch(uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    {:ok, _} =
      dispatch(uri, :turn, :dispatch, %{
        turn_id: turn_id,
        subtasks: [%{id: :page, mention: agent_uri("page"), prompt: "render"}]
      })

    {:ok, _} =
      dispatch(uri, :turn, :deliver, %{
        turn_id: turn_id,
        subtask_id: :page,
        card_ref: %{kind: :page, tree: page_tree}
      })

    {:ok, %{version: version}} =
      dispatch(uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})

    {turn_id, version}
  end

  defp settle(uri, turn_id) do
    {:ok, %{status: :settled}} = dispatch(uri, :turn, :settle, %{turn_id: turn_id})

    wait_until(fn ->
      case Ezagent.Socialware.Settlement.get(turn_id) do
        {:ok, %{status: :committed}} -> true
        _ -> false
      end
    end)
  end

  describe "committed page renders from the committed version" do
    test "after a full settle+commit, snapshot.page is the committed surface tree" do
      page_tree = %{type: "text", props: %{text: "committed page"}}
      uri = spawn_session()
      caller = test_caller(uri)
      {turn_id, _version} = compose_page(uri, page_tree)
      settle(uri, turn_id)

      {:ok, snapshot} = ExternalFeed.snapshot(uri, caller)
      assert snapshot.page == page_tree
    end
  end

  describe "page commit-gating (leak test)" do
    test "approved-but-uncommitted page does NOT leak (no settlement at all)" do
      page_tree = %{type: "text", props: %{text: "draft page"}}
      uri = spawn_session()
      caller = test_caller(uri)
      {_turn_id, version} = compose_page(uri, page_tree)

      # Approve the surface (advances the LIVE pointer) but never settle/commit.
      {:ok, _} = dispatch(uri, :surface, :approve, %{version: version})

      wait_until(fn ->
        {:ok, surface} = Ezagent.Kind.get_slice(uri, :surface)
        surface.approved == version
      end)

      {:ok, snapshot} = ExternalFeed.snapshot(uri, caller)
      assert snapshot.page == nil, "approved-but-uncommitted page must NOT leak"
      assert snapshot.messages == []
    end
  end

  describe "partial-commit gate: settlement pending" do
    test "a PENDING settlement (target version set, surface approved) does NOT expose a page" do
      page_tree = %{type: "text", props: %{text: "pending page"}}
      uri = spawn_session()
      caller = test_caller(uri)
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)
      {turn_id, version} = compose_page(uri, page_tree)

      {:ok, _} = dispatch(uri, :surface, :approve, %{version: version})

      # A PENDING settlement carrying the target version (status not flipped).
      {:ok, settlement} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: turn_id,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: version
        })

      assert settlement.status == :pending

      {:ok, snapshot} = ExternalFeed.snapshot(uri, caller)
      assert snapshot.page == nil
    end
  end

  describe "wake-up loss" do
    test "a committed page is visible via the durable snapshot even with no PubSub event" do
      page_tree = %{type: "text", props: %{text: "delivered despite lost wake-up"}}
      uri = spawn_session()
      caller = test_caller(uri)
      {turn_id, _version} = compose_page(uri, page_tree)
      settle(uri, turn_id)

      # We never subscribed to / received {:external_delivery}; a fresh snapshot
      # (== reconnect) still returns the committed page from the durable record.
      {:ok, snapshot} = ExternalFeed.snapshot(uri, caller)
      assert snapshot.page == page_tree
    end
  end

  describe "cold-read durability (codex rev4 HIGH): committed page survives a stopped session" do
    test "after the live session process is terminated, snapshot still returns the committed page" do
      page_tree = %{type: "text", props: %{text: "cold page"}}
      uri = spawn_session()
      caller = test_caller(uri)
      {turn_id, _version} = compose_page(uri, page_tree)
      settle(uri, turn_id)

      # The snapshot must be durable before we drop the process.
      wait_until(fn -> KindSnapshot.get(URI.to_string(uri)) != nil end)

      {:ok, pid} = Ezagent.KindRegistry.lookup(uri)

      :ok =
        DynamicSupervisor.terminate_child(
          # P5-1b: unified `Entity.Session` runs under instance_message's supervisor.
          EzagentDomainInstanceMessage.SessionSupervisor,
          pid
        )

      wait_until(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)

      # COLD path: the live membership auth needs a live `:session` slice, so the
      # production ingress (ExternalFeedController) revives a cold public session
      # from its durable snapshot via `ensure_live/1` BEFORE the read — mirror
      # that here. The PAGE itself is then served from the durable snapshot (the
      # committed page survives the process death), which is what this gate
      # asserts: the page is durable across a session restart.
      _ = Ezagent.SpawnRegistry.ensure_live(uri)
      wait_until(fn -> Ezagent.KindRegistry.lookup(uri) != :error end)

      {:ok, snapshot} = ExternalFeed.snapshot(uri, caller)
      assert snapshot.page == page_tree
    end
  end

  describe "cold-reconnect auth (codex rev4 MEDIUM): structural workspace, no registry binding" do
    test "snapshot authorizes a member even when the WorkspaceRegistry binding is gone" do
      page_tree = %{type: "text", props: %{text: "structural page"}}
      uri = spawn_session()
      caller = test_caller(uri)
      {turn_id, _version} = compose_page(uri, page_tree)
      settle(uri, turn_id)

      # Drop the volatile registry binding (simulating a restart where ETS is empty).
      :ok = Ezagent.WorkspaceRegistry.unbind(uri)
      assert Ezagent.WorkspaceRegistry.lookup(uri) == :error

      # Auth derives the workspace structurally -> still authorizes + returns the page.
      {:ok, snapshot} = ExternalFeed.snapshot(uri, caller)
      assert snapshot.page == page_tree
    end
  end
end

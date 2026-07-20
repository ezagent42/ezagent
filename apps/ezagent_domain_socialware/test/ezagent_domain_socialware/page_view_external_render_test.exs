defmodule EzagentDomainSocialware.PageViewExternalRenderTest do
  @moduledoc """
  P2 — PageView declares an external render target and produces it via the
  SAME projection the customer feed already uses (Surface.external_tree/1).
  Internal render (internal_tree) is unaffected.
  """
  # Spawns a real socialware-subset Entity.Session (touches KindSnapshot/Repo),
  # so this MUST use the Repo-sandbox case and run non-async (codex P2 review).
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.ActionSet.Surface
  alias EzagentDomainSocialware.PageView

  @owner Ezagent.URI.entity(:team_alpha, :user, "page-ext-owner")
  @stranger Ezagent.URI.entity(:team_alpha, :user, "page-ext-stranger")

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "page-ext-render-#{System.unique_integer([:positive])}"
    )
  end

  defp agent_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    target = target(session_uri, behavior, action)
    caller = User.admin_uri()

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        caps: Ezagent.Socialware.TestCapHelper.lifecycle_caps(session_uri, caller, target),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  # Spawn a fresh socialware session. `Surface.create/1` seeds
  # %{versions: %{}, approved: nil, version_seq: 0}, so there is NO approved
  # version yet — `external_tree` returns nil.
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

  # Drive a full turn to APPROVE a page version (auto-approve on settle) — the
  # exact seeding path the surface dispatch integration test exercises.
  defp approve_page(session_uri, page_tree) do
    {:ok, %{turn_id: turn_id}} =
      dispatch(session_uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    {:ok, _} =
      dispatch(session_uri, :turn, :dispatch, %{
        turn_id: turn_id,
        subtasks: [%{id: :page, mention: agent_uri("page"), prompt: "render"}]
      })

    {:ok, _} =
      dispatch(session_uri, :turn, :deliver, %{
        turn_id: turn_id,
        subtask_id: :page,
        card_ref: %{kind: :page, tree: page_tree}
      })

    {:ok, %{version: version}} =
      dispatch(session_uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})

    {:ok, %{status: :settled}} =
      dispatch(session_uri, :turn, :settle, %{turn_id: turn_id})

    wait_until(fn ->
      {:ok, surface} = Ezagent.Kind.get_slice(session_uri, :surface)
      surface.approved == version
    end)

    version
  end

  describe "external_render?/0" do
    test "PageView declares an external render target" do
      assert PageView.external_render?() == true
    end
  end

  describe "external_render/1,2 (caller-authorizing, PR-2)" do
    test "returns nil when there is no approved version" do
      uri = spawn_session()
      assert PageView.external_render(uri, @owner) == nil
    end

    test "returns the APPROVED version tree (== Surface.external_tree/1) for an authorized caller" do
      page_tree = %{type: "text", props: %{text: "live page"}}
      uri = spawn_session()
      _version = approve_page(uri, page_tree)

      {:ok, surface} = Ezagent.Kind.get_slice(uri, :surface)
      assert PageView.external_render(uri, @owner) == Surface.external_tree(surface)
      assert PageView.external_render(uri, @owner) == page_tree
    end

    test "fails closed for a non-member and for a caller-less read (PR-2 authz)" do
      page_tree = %{type: "text", props: %{text: "live page"}}
      uri = spawn_session()
      _version = approve_page(uri, page_tree)

      # A non-member gets nil even though a committed page exists...
      assert PageView.external_render(uri, @stranger) == nil
      # ...and the caller-less /1 form (the SessionView contract) fails closed on
      # a private session — before PR-2 it returned the tree with NO authorization.
      assert PageView.external_render(uri) == nil
    end

    test "returns nil for a non-URI argument (clause fallback)" do
      assert PageView.external_render(:not_a_uri) == nil
      assert PageView.external_render(:not_a_uri, @owner) == nil
    end
  end
end

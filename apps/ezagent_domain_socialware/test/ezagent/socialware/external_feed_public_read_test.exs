defmodule Ezagent.Socialware.ExternalFeedPublicReadTest do
  @moduledoc """
  A signed-in NON-member may READ a `public_view` session's external page (the
  same public surface an anonymous visitor sees), while remaining a non-member
  (`member? == false`) so the surface offers the "加入" join affordance rather
  than the "发送" composer.

  Regression guard for the ingress asymmetry bug: anonymous visitors were
  auto-joined read-only at ingress and could view a public page, but a signed-in
  non-member was returned unchanged (never joined) and the membership-only read
  gate then denied them — so logging in made a public page LESS viewable ("无权限"),
  and the front-end "加入" button was unreachable.

  The fix opens the READ gate (`read_authorized/2`) for `public_view` sessions
  without touching the strict `authorize/2` membership predicate that still gates
  participation (post) and the `member?` flag. A PRIVATE session stays strict
  member-only — proven below.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate}
  alias Ezagent.{Capability, KindRegistry}
  alias Ezagent.Socialware.{DefinitionRegistry, ExternalFeed, Installation}

  @workspace "team-alpha"
  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "pub-read-owner")

  # A logged-in principal that is NOT the owner and never joined the session —
  # a real signed-in user (not an anon) who opens someone else's public page.
  defp non_member, do: Ezagent.URI.new!("entity://team-alpha/user/pub-read-stranger")

  # A live team-alpha session with a socialware install whose definition declares
  # `web_anon_access` per `flag` (true = public_view, false = private).
  defp session_with(flag) do
    u = System.unique_integer([:positive])
    name = "pub-read-def-#{u}"

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(definition(name, flag),
        workspace_uri: Ezagent.URI.workspace(@workspace)
      )

    content = %{name: "pub-read-tmpl-#{u}", installs: [name]}
    {:ok, tmpl_uri} = SessionTemplate.persist_version_as_system(content, @workspace)

    session_uri = Ezagent.URI.new!("session://#{@workspace}/default/pub-read-#{u}")

    {:ok, behaviors} =
      Installation.behavior_set_for_template(content, Ezagent.URI.workspace(@workspace))

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session_uri,
        owner_uri: owner(),
        behaviors: behaviors
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    :ok =
      Installation.install_template_installs(
        session_uri,
        Ezagent.URI.workspace(@workspace),
        content,
        owner()
      )

    {:ok, _} =
      ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl_uri})

    on_exit(fn -> terminate(session_uri) end)
    session_uri
  end

  defp definition(name, web_anon_access) do
    %{
      name: name,
      bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
      shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
      owner_policy: %{type: :installer},
      visibility_policy: %{publish_policy: :auto, web_anon_access: web_anon_access}
    }
  end

  defp terminate(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

      :error ->
        :ok
    end
  end

  describe "public_view session — signed-in non-member reads the public page" do
    test "snapshot / join / replay succeed for a signed-in non-member" do
      session = session_with(true)
      stranger = non_member()

      assert {:ok, %{page: _, messages: _}} = ExternalFeed.snapshot(session, stranger)
      assert {:ok, %{snapshot: _, cursor: _}} = ExternalFeed.join(session, stranger)
      assert {:ok, %{snapshot: _, cursor: _}} = ExternalFeed.replay(session, stranger, 0)
    end

    test "the non-member reads as member? == false (surface shows 加入, not 发送)" do
      session = session_with(true)
      refute ExternalFeed.member?(session, non_member())
    end

    test "the owner reads AND is member? == true (surface shows 发送)" do
      session = session_with(true)
      assert {:ok, _} = ExternalFeed.snapshot(session, owner())
      assert ExternalFeed.member?(session, owner())
    end
  end

  describe "private session — the read gate stays strict member-only (fail closed)" do
    test "a non-member is denied snapshot / join / replay on a NON-public session" do
      session = session_with(false)
      stranger = non_member()

      assert {:error, :unauthorized} = ExternalFeed.snapshot(session, stranger)
      assert {:error, :unauthorized} = ExternalFeed.join(session, stranger)
      assert {:error, :unauthorized} = ExternalFeed.replay(session, stranger, 0)
      refute ExternalFeed.member?(session, stranger)
    end

    test "the owner still reads a private session" do
      session = session_with(false)
      assert {:ok, _} = ExternalFeed.snapshot(session, owner())
      assert ExternalFeed.member?(session, owner())
    end
  end
end

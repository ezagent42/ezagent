defmodule EzagentPluginLiveview.ComposerMentionTest do
  @moduledoc """
  Mention-gated routing §6.9 — the real-LiveView-composer test.

  `docs/superpowers/specs/2026-05-22-mention-gated-routing.md` §6.9
  (codex rev 3 MEDIUM-c): the new `system_default` rule
  (`{:always} → [$session_users, $mentions]`) is only useful if the
  ACTUAL compose surface populates `Message.mentions`. A synthetic
  `message.mentions` test would not prove that.

  This test drives the production `chat_compose` LiveView event with
  text containing an `@entity://...` mention, and verifies the
  mentioned (and joined) agent receives a `chat.receive` dispatch —
  proving the compose → `Ezagent.Message.mentions` → Resolver
  `$mentions` path is wired end-to-end and the new default is not a
  silent no-op on the real surface.
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query

  @endpoint EzagentWeb.Endpoint

  @session URI.new!("session://default/system/main")

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  defp receive_dispatch_count(target_uri) do
    prefix = "#{URI.to_string(target_uri)}?action=chat.receive"

    EzagentCore.Repo.aggregate(
      from(i in "invocations",
        where:
          fragment("? LIKE ?", i.target, ^"#{prefix}%") and
            i.authz == "granted"
      ),
      :count
    )
  end

  defp join(member) do
    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: URI.new!("#{URI.to_string(@session)}?action=chat.join"),
        mode: :cast,
        args: %{member: member},
        ctx: %{
          caller: member,
          caps: Ezagent.Entity.User.admin_caps(),
          reply: :ignore
        }
      })

    Process.sleep(80)
  end

  test "composing '@<agent_uri>' actuates exactly that mentioned, joined agent", %{conn: conn} do
    # A real echo agent joined to the default session. valid_member?/2
    # requires the mention to be a registered member, so it MUST join.
    agent = URI.new!("entity://agent/team-alpha/echo_compose-#{System.unique_integer([:positive])}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(agent)
    join(agent)

    before = receive_dispatch_count(agent)

    {:ok, lv, _html} = live(conn, "/sessions")

    # The composer's parse_mentions/1 extracts `@entity://...` from the
    # raw compose text — this is the production compose → mentions path.
    text = "hey @#{URI.to_string(agent)} please look at this #{System.unique_integer([:positive])}"

    lv
    |> form("form[phx-submit=chat_compose]", %{"chat" => %{"text" => text}})
    |> render_submit()

    # Audit writes flush asynchronously — force + wait.
    if Process.whereis(Ezagent.Audit.Writer), do: send(Ezagent.Audit.Writer, :flush)
    Process.sleep(400)

    assert receive_dispatch_count(agent) > before,
           "composing '@<agent_uri>' through the real LiveView composer must " <>
             "populate Message.mentions and actuate the mentioned agent — " <>
             "the compose → $mentions path is not wired"
  end

  test "composing plain agent-name text (no @) does NOT actuate the agent", %{conn: conn} do
    # The mention-gated default actuates ONLY on a validated @-mention.
    # Plain prose naming the agent must not.
    agent = URI.new!("entity://agent/team-alpha/echo_plain-#{System.unique_integer([:positive])}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(agent)
    join(agent)

    before = receive_dispatch_count(agent)

    {:ok, lv, _html} = live(conn, "/sessions")

    # No `@` prefix — just the agent's name in prose.
    text = "hi echo_plain can you help #{System.unique_integer([:positive])}"

    lv
    |> form("form[phx-submit=chat_compose]", %{"chat" => %{"text" => text}})
    |> render_submit()

    if Process.whereis(Ezagent.Audit.Writer), do: send(Ezagent.Audit.Writer, :flush)
    Process.sleep(400)

    assert receive_dispatch_count(agent) == before,
           "plain agent-name text (no @mention) must NOT actuate the agent — " <>
             "mention is the routing primitive"
  end
end

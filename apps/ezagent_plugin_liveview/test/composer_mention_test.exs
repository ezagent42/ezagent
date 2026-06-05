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

  defp ensure_workspace_seeded!(%URI{scheme: "workspace", host: name})
       when is_binary(name) and name != "" do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        case Ezagent.Workspace.create(name, %{}) do
          {:ok, _pid} -> :ok
          {:error, :workspace_exists} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to seed workspace #{name}: #{inspect(reason)}"
        end

      _ ->
        :ok
    end
  end

  # This test counts persisted audit rows (the `invocations` table) to
  # prove the mention actuated the agent. Audit rows are written by the
  # async `Ezagent.Audit.Writer`, which is DELIBERATELY skipped from the
  # boot supervision tree in `:test` (it stamps over sandbox connections
  # of exited tests). `Ezagent.Test.AuditCase` is the opt-in that
  # `start_supervised!`s the Writer per-test AND `Sandbox.allow`s it onto
  # the per-test connection — without it the `:invoke :stop` casts hit a
  # dead name and no row is ever persisted, so the count stays 0 forever.
  # (post-lifecycle remediation: the test asserted on audit rows without
  # opting into the Writer.)
  use Ezagent.Test.AuditCase, writers: [:audit]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query

  @endpoint EzagentWeb.Endpoint

  # The mentioned agents live in `entity://team-alpha/agent/…`. The
  # Resolver's `valid_member?/3` trust boundary drops any candidate whose
  # workspace segment differs from the session's (check #3), so a
  # team-alpha agent mentioned in a `system` session is rejected and
  # never actuated. The session — and the operator's viewed workspace —
  # must therefore be team-alpha so the mention validates in-workspace.
  # (post-lifecycle remediation: the session was pinned to `system` while
  # the agents were team-alpha.)
  @session URI.new!("session://team-alpha/default/main")

  # AuditCase's `setup` already checks out + shares the sandbox and
  # starts/allows the Writer; this `setup` only builds the conn.
  setup do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://team-alpha"
      })

    {:ok, conn: conn}
  end

  defp receive_dispatch_count(target_uri) do
    # The audit row's target embeds the action as a `?action=…receive`
    # query. Chat fan-out now dispatches via `Ezagent.Router.dispatch/1`
    # (the §11 facade-consistency migration), which annotates the target
    # with `?action=_.receive` (the `_.` behavior-name placeholder a
    # `%Cmd{}` carries) rather than the legacy `?action=chat.receive`.
    # Match the action suffix so the count is robust to the behavior-name
    # prefix. (post-lifecycle remediation.)
    base = URI.to_string(target_uri)

    EzagentCore.Repo.aggregate(
      from(i in "invocations",
        where:
          fragment("? LIKE ?", i.target, ^"#{base}?action=%receive%") and
            i.authz == "granted"
      ),
      :count
    )
  end

  defp create_session_via_workspace(short_name, creator_uri, opts) do
    template_name = Keyword.fetch!(opts, :template_name)

    workspace_uri =
      Keyword.get(opts, :workspace_uri, Ezagent.Capability.workspace_of(creator_uri))

    ensure_workspace_seeded!(workspace_uri)

    with {:ok, result} <-
           Ezagent.Workspace.create_session(
             workspace_uri,
             %{short_name: short_name, template_name: template_name},
             %{caller: creator_uri, caps: Ezagent.SystemPrincipal.caps("system://bootstrap")}
           ) do
      {:ok, result.session_uri,
       %{
         orchestrator_uri: result.orchestrator_uri,
         orchestrator_status: result.orchestrator_status,
         orchestrator_error: result.orchestrator_error
       }}
    end
  end

  # Ensure the team-alpha main session Kind is live BEFORE any join —
  # the agents join `@session` via a fire-and-forget cast, which would
  # be dropped with `:no_such_actor` if the session weren't spawned yet
  # (it is created lazily on LV mount, which happens AFTER these joins).
  defp ensure_session do
    case Ezagent.KindRegistry.lookup(@session) do
      {:ok, _pid} ->
        :ok

      :error ->
        {:ok, _spawned, _meta} =
          create_session_via_workspace("main", Ezagent.Entity.User.admin_uri(),
            template_name: "default",
            workspace_uri: Ezagent.Capability.workspace_of(@session)
          )

        :ok
    end
  end

  defp join(member) do
    :ok = ensure_session()

    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: URI.new!("#{URI.to_string(@session)}?action=chat.join"),
        mode: :cast,
        args: %{member: member},
        ctx: %{
          caller: member,
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: :ignore
        }
      })

    Process.sleep(80)
  end

  test "composing '@<agent_uri>' actuates exactly that mentioned, joined agent", %{conn: conn} do
    # A real echo agent joined to the default session. valid_member?/2
    # requires the mention to be a registered member, so it MUST join.
    agent =
      URI.new!("entity://team-alpha/agent/echo_compose-#{System.unique_integer([:positive])}")

    {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent, "echo")
    join(agent)

    before = receive_dispatch_count(agent)

    {:ok, lv, _html} = live(conn, "/sessions")

    # The composer's parse_mentions/1 extracts `@entity://...` from the
    # raw compose text — this is the production compose → mentions path.
    text =
      "hey @#{URI.to_string(agent)} please look at this #{System.unique_integer([:positive])}"

    lv
    |> form("form[phx-submit=chat_compose]", %{"chat" => %{"text" => text}})
    |> render_submit()

    # The chat.receive dispatch + its audit row are written by the async
    # Audit.Writer; poll (flush + re-query) instead of a single fixed
    # sleep so the assertion isn't flaky under serial/--trace scheduling.
    assert wait_for_dispatch(agent, before),
           "composing '@<agent_uri>' through the real LiveView composer must " <>
             "populate Message.mentions and actuate the mentioned agent — " <>
             "the compose → $mentions path is not wired"
  end

  # Poll up to ~2s for the receive-dispatch count to exceed `before`.
  defp wait_for_dispatch(agent, before, retries \\ 40)
  defp wait_for_dispatch(_agent, _before, 0), do: false

  defp wait_for_dispatch(agent, before, retries) do
    if Process.whereis(Ezagent.Audit.Writer), do: send(Ezagent.Audit.Writer, :flush)

    if receive_dispatch_count(agent) > before do
      true
    else
      Process.sleep(50)
      wait_for_dispatch(agent, before, retries - 1)
    end
  end

  test "composing plain agent-name text (no @) does NOT actuate the agent", %{conn: conn} do
    # The mention-gated default actuates ONLY on a validated @-mention.
    # Plain prose naming the agent must not.
    agent = URI.new!("entity://team-alpha/agent/echo_plain-#{System.unique_integer([:positive])}")
    {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent, "echo")
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

defmodule EzagentDomainChat.Integration.DynamicSessionTest do
  @moduledoc """
  Phase 3b-step 1: dynamic non-main Session create flow.
  """

  use ExUnit.Case
  alias Ezagent.{KindRegistry, Entity.User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  test "create_session spawns Session Kind + joins creator" do
    short = "dyn-#{System.unique_integer([:positive])}"
    admin_uri = User.admin_uri()
    # SPEC #324: workspace is derived structurally from the creator URI.
    # Admin's URI is `entity://user/system/admin` → workspace `system`.
    # SPEC #366 (Allen 2026-05-26) — `:template_name` is now required.
    assert {:ok, session_uri, _meta} =
             EzagentDomainChat.create_session(short, admin_uri, template_name: "default")

    assert URI.to_string(session_uri) == "session://default/system/#{short}"

    # KindRegistry has it
    assert {:ok, pid} = KindRegistry.lookup(session_uri)
    assert Process.alive?(pid)

    # admin in members (poll briefly for cast to land)

    assert wait_until(fn ->
             # Lifecycle migration (SPEC 2026-05-29 §2.3C): `members` lives
             # under the Chat slice's persistent `:state`.
             %{state: %{chat: %{state: slice}}} = :sys.get_state(pid)
             Map.has_key?(slice.members, admin_uri)
           end)
  end

  test "create_session is idempotent — re-call returns same URI" do
    short = "idemp-#{System.unique_integer([:positive])}"
    admin_uri = User.admin_uri()
    assert {:ok, uri1, _meta1} =
             EzagentDomainChat.create_session(short, admin_uri, template_name: "default")

    assert {:ok, uri2, _meta2} =
             EzagentDomainChat.create_session(short, admin_uri, template_name: "default")

    assert uri1 == uri2
  end

  test "empty short-name is rejected" do
    # PR-J — the legacy `:main_is_static` rejection was dropped (main is
    # now created via this same facade by the first-login wizard).
    # An empty string still doesn't make sense as a session name.
    assert {:error, :short_name_required} =
             EzagentDomainChat.create_session("", User.admin_uri(), template_name: "default")
  end

  test "list_sessions includes main + any dynamic sessions" do
    short = "listed-#{System.unique_integer([:positive])}"
    {:ok, _, _meta} =
      EzagentDomainChat.create_session(short, User.admin_uri(), template_name: "default")

    uris = EzagentDomainChat.list_sessions() |> Enum.map(&URI.to_string/1)
    assert "session://default/system/main" in uris
    assert "session://default/system/#{short}" in uris
  end

  # Task #55 (Allen 2026-05-27) — workspace-scoped session listing
  # for the LV sidebar / `/admin/sessions`. The unfiltered `/0`
  # variant leaked cross-workspace sessions to every LV mount.
  test "list_sessions/1 filters by workspace_uri" do
    short = "ws-scoped-#{System.unique_integer([:positive])}"

    {:ok, _, _meta} =
      EzagentDomainChat.create_session(short, User.admin_uri(), template_name: "default")

    system_uris =
      "workspace://system"
      |> URI.parse()
      |> EzagentDomainChat.list_sessions()
      |> Enum.map(&URI.to_string/1)

    other_uris =
      "workspace://team-alpha-#{System.unique_integer([:positive])}"
      |> URI.parse()
      |> EzagentDomainChat.list_sessions()
      |> Enum.map(&URI.to_string/1)

    assert "session://default/system/#{short}" in system_uris
    refute "session://default/system/#{short}" in other_uris
  end

  defp wait_until(fun, retries \\ 50) do
    case fun.() do
      false when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end
end

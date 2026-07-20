defmodule Ezagent.Session.TemplateReadsTest do
  @moduledoc """
  Contract test for the workspace session-template list read chokepoint
  (`Ezagent.Session.TemplateReads`) — read-plane PR-4 rework.

  The discriminating cases: a declared workspace member (or an operator)
  gets the workspace's template rows (live ∪ durable); a cap-scoped
  NON-member gets `[]` (templates are the workspace's shared resource —
  not for anyone who merely passes the coarse workspace gate); an
  unavailable enumeration facade fails closed to `[]`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Session.TemplateReads

  defmodule FakeRegistry do
    @moduledoc false
    def list_all, do: Process.get({:fake_template_registry, :entries}, [])
  end

  defmodule FakeSnapshot do
    @moduledoc false
    def list_all, do: Process.get({:fake_template_snapshot, :rows}, [])
  end

  defmodule FakeSessionFacade do
    @moduledoc false
    def ensure_template_alive(%URI{}), do: {:ok, self()}

    def read_template_content(%URI{} = uri) do
      {:ok,
       Map.get(Process.get({:fake_template_session, :contents}, %{}), URI.to_string(uri), %{})}
    end
  end

  setup do
    ws_name = "ws-template-reads-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Ezagent.Workspace.create(ws_name, %{})

    member = Ezagent.URI.user(ws_name, "member")
    outsider = Ezagent.URI.user(ws_name, "outsider")

    for uri <- [member, outsider] do
      {:ok, _row} = Ezagent.Users.create(uri, nil, [])
    end

    {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [member])

    Application.put_env(:ezagent_domain_session, :template_registry_facade, FakeRegistry)
    Application.put_env(:ezagent_domain_session, :template_snapshot_facade, FakeSnapshot)
    Application.put_env(:ezagent_domain_session, :template_session_facade, FakeSessionFacade)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_session, :template_registry_facade)
      Application.delete_env(:ezagent_domain_session, :template_snapshot_facade)
      Application.delete_env(:ezagent_domain_session, :template_session_facade)
    end)

    {:ok, ws_name: ws_name, member: member, outsider: outsider}
  end

  test "session_templates/2: a declared workspace member gets live ∪ durable rows",
       %{ws_name: ws_name, member: member} do
    live_uri = "template://#{ws_name}/session/live-tpl@aaa111"
    durable_uri = "template://#{ws_name}/session/durable-tpl@bbb222"
    other_ws_uri = "template://other-ws/session/foreign@ccc333"

    Process.put({:fake_template_registry, :entries}, [
      {live_uri, self()},
      # non-template kinds and other workspaces are filtered out
      {"session://#{ws_name}/default/main", self()},
      {other_ws_uri, self()}
    ])

    Process.put({:fake_template_session, :contents}, %{
      live_uri => %{"name" => "live-template", "description" => "the live one"}
    })

    Process.put({:fake_template_snapshot, :rows}, [
      %{uri: live_uri, kind_type: "session_template"},
      %{uri: durable_uri, kind_type: "session_template"},
      %{uri: "session://#{ws_name}/default/x", kind_type: "session"},
      %{uri: other_ws_uri, kind_type: "session_template"}
    ])

    rows = TemplateReads.session_templates(member, ws_name)

    assert [durable, live] = rows

    # Sorted by {name, uri}: "durable-tpl" < "live-template".
    assert durable["uri"] == durable_uri
    assert durable["name"] == "durable-tpl"
    assert durable["alive"] == false
    assert durable["source"] == "session_template"

    assert live["uri"] == live_uri
    assert live["name"] == "live-template"
    assert live["alive"] == true
    assert live["description"] == "the live one"

    # The foreign-workspace template appears NOWHERE.
    refute Enum.any?(rows, &(&1["uri"] == other_ws_uri))
  end

  test "session_templates/2: a cap-scoped NON-member gets [] (fail-closed)", %{
    ws_name: ws_name,
    member: member,
    outsider: outsider
  } do
    Process.put({:fake_template_registry, :entries}, [
      {"template://#{ws_name}/session/live-tpl@aaa111", self()}
    ])

    assert TemplateReads.session_templates(outsider, ws_name) == []
    assert TemplateReads.session_templates(nil, ws_name) == []
    assert TemplateReads.session_templates(member, "nonexistent-ws") == []
  end

  test "session_templates/2: an operator (promoted, non-bootstrap) gets the rows", %{
    ws_name: ws_name
  } do
    live_uri = "template://#{ws_name}/session/live-tpl@aaa111"
    Process.put({:fake_template_registry, :entries}, [{live_uri, self()}])

    operator =
      Ezagent.URI.new!("entity://system/user/op-#{System.unique_integer([:positive])}")

    assert [%{"uri" => ^live_uri}] = TemplateReads.session_templates(operator, ws_name)
  end

  test "session_templates/2: an unavailable registry facade fails closed to []", %{
    ws_name: ws_name,
    member: member
  } do
    Application.put_env(:ezagent_domain_session, :template_registry_facade, __MODULE__.Defunct)

    assert TemplateReads.session_templates(member, ws_name) == []
  end

  defmodule Defunct do
    @moduledoc false
  end
end

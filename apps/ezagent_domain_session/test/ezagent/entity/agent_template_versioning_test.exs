defmodule Ezagent.Entity.AgentTemplateVersioningTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  alias Ezagent.Entity.{AgentTemplate, User}

  defp uniq, do: System.unique_integer([:positive])

  defp read(uri) do
    target = Ezagent.URI.with_action(uri, :template, :read)
    admin = User.admin_uri()

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: admin,
        caps: MapSet.new([signed_action_cap!(target, admin)]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  test "persist_version_as_system mints a new source_template_uri when content changes" do
    name = "agent-versioned-#{uniq()}"

    v1 = %{
      name: name,
      flavor: "cc",
      project_cwd: "/tmp/v1",
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-21 00:00:00Z]
    }

    v2 = %{v1 | project_cwd: "/tmp/v2"}

    assert {:ok, uri1} = AgentTemplate.persist_version_as_system(v1, "team-alpha")
    assert {:ok, uri2} = AgentTemplate.persist_version_as_system(v2, "team-alpha")

    assert uri1 != uri2
    assert URI.to_string(uri1) =~ "template://team-alpha/agent/#{name}@"
    assert URI.to_string(uri2) =~ "template://team-alpha/agent/#{name}@"

    assert {:ok, %{content: c1}} = read(uri1)
    assert {:ok, %{content: c2}} = read(uri2)
    assert c1.project_cwd == "/tmp/v1"
    assert c2.project_cwd == "/tmp/v2"
  end
end

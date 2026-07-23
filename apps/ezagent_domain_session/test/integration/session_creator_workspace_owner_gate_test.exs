defmodule EzagentDomainInstanceMessage.Integration.SessionCreatorWorkspaceOwnerGateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{RuntimeIdentity, WorkspacePlacement}
  alias Ezagent.Entity.User
  alias EzagentDomainInstanceMessage.SessionCreator

  defmodule RemoteResolver do
    @behaviour Ezagent.WorkspacePlacement

    @impl true
    def owner_of(%URI{scheme: "workspace"}), do: {:ok, "remote-node"}
  end

  setup do
    previous_identity = Application.get_env(:ezagent_core, RuntimeIdentity)
    previous_placement = Application.get_env(:ezagent_core, WorkspacePlacement)

    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "local-node")

    Application.put_env(:ezagent_core, WorkspacePlacement,
      resolver: RemoteResolver,
      mode: :enforce
    )

    on_exit(fn ->
      restore_env(RuntimeIdentity, previous_identity)
      restore_env(WorkspacePlacement, previous_placement)
    end)

    :ok
  end

  test "create_session fails before materializing live session state when workspace is owned remotely" do
    short = "owner-gate-#{System.unique_integer([:positive])}"
    session_uri = Ezagent.URI.new!("session://system/default/#{short}")
    workspace_uri = Ezagent.URI.new!("workspace://system")

    assert {:error,
            {:not_workspace_owner, ^workspace_uri, "remote-node", "local-node",
             {:session_create, ^session_uri}}} =
             SessionCreator.create_session(short, User.admin_uri(), template_name: "default")

    assert :error = Ezagent.KindRegistry.lookup(session_uri)
  end

  defp restore_env(module, nil), do: Application.delete_env(:ezagent_core, module)
  defp restore_env(module, value), do: Application.put_env(:ezagent_core, module, value)
end

defmodule Ezagent.ActionSet.WorkspaceUserAdminMigrationParityTest do
  @moduledoc """
  P2-b migration parity test (SPEC #445 §7.3 Level 1).

  Validates that the migrated `Ezagent.ActionSet.WorkspaceUserAdmin`
  produces the same dispatch-visible outcome via the new-contract
  path (`Kind.Runtime.handle_dispatch/4` → `handle_create_user/2`)
  as the legacy `invoke/4` did pre-migration.

  Uses a stub Workspace Kind (the real `Ezagent.Entity.Workspace` is
  in `ezagent_domain_workspace`; we don't need the full Kind to
  exercise the dispatch contract). The full end-to-end happy path
  lives in `apps/ezagent_domain_workspace/test/integration/create_user_dispatch_test.exs`.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_invocation!: 2, signed_required_cap!: 5]

  alias Ezagent.{BehaviorRegistry, Invocation}
  alias Ezagent.ActionSet.WorkspaceUserAdmin

  defmodule StubWorkspaceKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :wua_parity_stub
    @impl true
    def behaviors, do: [Ezagent.ActionSet.WorkspaceUserAdmin]
    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = BehaviorRegistry.register(StubWorkspaceKind, :create_user, WorkspaceUserAdmin)

    n = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.new!("workspace://wua-parity-#{n}")
    state = %{workspace_user_admin: WorkspaceUserAdmin.init_slice(%{})}

    {:ok, workspace_uri: workspace_uri, state: state}
  end

  defp build_invocation(workspace_uri, action, args) do
    target =
      Ezagent.URI.new!("#{URI.to_string(workspace_uri)}?action=workspace_user_admin.#{action}")

    admin = Ezagent.URI.user(:system, :admin)
    cap = signed_required_cap!(target, :wua_parity_stub, WorkspaceUserAdmin, action, admin)

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: admin, caps: MapSet.new([cap]), reply: :sync}
    }
    |> signed_invocation!(:wua_parity_stub)
  end

  describe "Level 1 — dispatch parity through Kind.Runtime" do
    test "create_user happy path inserts row + bumps create_count + emits event",
         %{workspace_uri: workspace_uri, state: state} do
      user_uri_str = URI.to_string(workspace_uri) |> String.replace("workspace://", "")
      user_uri = "entity://#{user_uri_str}/user/parity-alice"

      inv =
        build_invocation(workspace_uri, :create_user, %{
          user_uri: user_uri,
          password: "test-pw",
          caps: ""
        })

      assert {:ok, new_state,
              %{
                user_uri: ^user_uri,
                caps_granted: _,
                password_set: true,
                spawned: _
              }, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(
                 inv,
                 state,
                 StubWorkspaceKind,
                 workspace_uri
               )

      # Phase B: two-container slice — persistent counter lives under `.state`.
      assert new_state.workspace_user_admin.state.create_count == 1
      # Row inserted in the users table.
      assert Ezagent.Users.get_by_uri(user_uri) != nil
    end

    test "create_user with cross-workspace user URI is refused",
         %{workspace_uri: workspace_uri, state: state} do
      # User URI's workspace segment doesn't match dispatch target's.
      cross_user_uri = "entity://different-workspace/user/alice"

      inv =
        build_invocation(workspace_uri, :create_user, %{
          user_uri: cross_user_uri,
          password: nil,
          caps: ""
        })

      assert {:error, {:cross_workspace_user, _details}} =
               Ezagent.Kind.Runtime.handle_dispatch(
                 inv,
                 state,
                 StubWorkspaceKind,
                 workspace_uri
               )
    end

    test "create_user with missing user_uri arg fails InterfaceValidator (pre-handler)",
         %{workspace_uri: workspace_uri, state: state} do
      # InterfaceValidator runs at dispatch step 4 (pre-handler) and
      # rejects missing required args. The handler's defensive
      # `:user_uri_required` branch covers the direct-call surface but
      # is unreachable via the live dispatch path — that's intentional
      # defence in depth.
      inv = build_invocation(workspace_uri, :create_user, %{})

      assert {:error, {:invalid_args, _}} =
               Ezagent.Kind.Runtime.handle_dispatch(
                 inv,
                 state,
                 StubWorkspaceKind,
                 workspace_uri
               )
    end
  end
end

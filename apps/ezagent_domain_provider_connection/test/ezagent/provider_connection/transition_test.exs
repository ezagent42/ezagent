defmodule Ezagent.ProviderConnection.TransitionTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{Connection, Transition}
  alias EzagentCore.Repo

  test "mutation on a terminal connection returns the closed connection_terminal error" do
    for terminal <- ["revoked", "disconnected", "failed"] do
      connection = insert_connection!(terminal)

      assert {:error, :connection_terminal} =
               Transition.mutate(
                 connection.connection_id,
                 connection.connection_version,
                 :active,
                 fn _ ->
                   {:ok, %{}}
                 end
               ),
             "expected #{terminal} to fail closed"
    end
  end

  test "mutation on a missing connection returns connection_not_found" do
    assert {:error, :connection_not_found} =
             Transition.mutate(Ecto.UUID.generate(), 0, :active, fn _ -> {:ok, %{}} end)
  end

  defp insert_connection!(status) do
    failed? = status == "failed"

    %{
      connection_id: Ecto.UUID.generate(),
      workspace_uri: "workspace://acme",
      owner_uri: "entity://acme/user/transition-test",
      provider_id: "transition-provider",
      governed_host: "git.example",
      external_account_id:
        if(failed?, do: nil, else: "acct-#{System.unique_integer([:positive])}"),
      display_login: if(failed?, do: nil, else: "transition-user"),
      execution_identity: if(failed?, do: nil, else: "connected_user_account_1"),
      requested_execution_identity_class: "connected_user",
      acquisition_method: "oauth_user",
      authorization_backend_ref: if(failed?, do: nil, else: "authorization-ref"),
      credential_backend_ref: if(failed?, do: nil, else: "credential-ref"),
      backend_pair_id: nil,
      authorization_backend_id: nil,
      credential_backend_id: nil,
      status: status,
      last_error_code: if(failed?, do: "account_conflict", else: nil)
    }
    |> Connection.create_changeset()
    |> Ecto.Changeset.change(connection_version: 0, credential_version: 0)
    |> Repo.insert!()
  end

  test "the legal transition graph is the exact frozen edge table" do
    edges = [
      {:pending_authorization, :active},
      {:active, :refresh_required},
      {:refresh_required, :refreshing},
      {:refreshing, :active},
      {:active, :degraded},
      {:refresh_required, :degraded},
      {:refreshing, :degraded},
      {:active, :expired},
      {:refresh_required, :expired},
      {:refreshing, :expired},
      {:degraded, :expired},
      {:active, :revoking},
      {:degraded, :revoking},
      {:expired, :revoking},
      {:revoking, :revoked},
      {:active, :disconnecting},
      {:degraded, :disconnecting},
      {:expired, :disconnecting},
      {:disconnecting, :disconnected}
    ]

    statuses = Ezagent.ProviderConnection.Types.statuses()
    actual = for from <- statuses, to <- statuses, Transition.allowed?(from, to), do: {from, to}

    assert MapSet.new(actual) == MapSet.new(edges)
    refute Transition.allowed?(:revoked, :active)
    refute Transition.allowed?(:disconnected, :pending_authorization)
  end
end

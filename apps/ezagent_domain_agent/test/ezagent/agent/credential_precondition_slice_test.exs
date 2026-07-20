defmodule Ezagent.Agent.CredentialPreconditionSliceTest do
  @moduledoc """
  #185 — the spawn-time credential precondition for SLICE-backed flavors (curl:
  the key lives in the agent's `:api_keys` slice, not in config-home files and
  not in an env var).

  Before #185 `check_source/4` waved every slice-backed flavor through
  (`credential_relpaths/0 == []`, no `credential_status/2`), so a curl agent
  that DECLARES a required credential spawned keyless and only failed at the
  visitor's first reply (`{:no_api_key, provider}`). Now the precondition fires
  for a slice-backed flavor whose template marks the credential required, and
  stays silent where the recipe intends keyless (`credential_optional`).

  Exercised through a FAKE slice-credentialled Template Class (like the sibling
  `credential_status_test.exs`'s `SliceTC`) — `ezagent_domain_agent` deliberately
  has no compile dep on any plugin, so the real curl Template Class is not on
  the code path here.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.CredentialPrecondition
  alias Ezagent.Credential.WorkspaceSharedSource
  alias EzagentCore.Repo

  # A slice-credentialled fake flavor (like curl) — creds in the :api_keys slice.
  defmodule SliceTC do
    @behaviour Ezagent.Agent.CredentialSliceAdapter
    def credential_slice, do: :api_keys
    def materialize_credential_slice(_uri, _data), do: :ok
  end

  defp register_slice_flavor do
    flavor = "curl-fake-#{System.unique_integer([:positive])}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: SliceTC
      })

    flavor
  end

  defp installer, do: Ezagent.URI.user(:system, "slice-#{System.unique_integer([:positive])}")
  defp workspace, do: Ezagent.URI.workspace(:system)

  test "a slice-backed flavor with a REQUIRED credential and no source is skipped loud" do
    flavor = register_slice_flavor()

    assert {:skip, {:no_credential_source, ^flavor}} =
             CredentialPrecondition.check_source(installer(), workspace(), flavor)
  end

  test "credential_optional opts OUT of the precondition (intentional keyless recipe)" do
    flavor = register_slice_flavor()

    assert :ok =
             CredentialPrecondition.check_source(installer(), workspace(), flavor,
               credential_optional: true
             )
  end

  test "a resolved workspace-shared source satisfies the required slice credential" do
    flavor = register_slice_flavor()
    ws = workspace()
    source = "entity://system/agent/slice-src-#{System.unique_integer([:positive])}"

    {:ok, _} =
      %{
        workspace_uri: URI.to_string(ws),
        flavor: flavor,
        source_uri: source,
        set_by: URI.to_string(Ezagent.Entity.User.admin_uri())
      }
      |> WorkspaceSharedSource.changeset()
      |> Repo.insert()

    assert :ok = CredentialPrecondition.check_source(installer(), ws, flavor)
  end

  test "regression: a credential-less flavor is still never skipped" do
    assert :ok =
             CredentialPrecondition.check_source(
               installer(),
               workspace(),
               "no-such-flavor-#{System.unique_integer([:positive])}"
             )
  end
end

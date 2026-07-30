defmodule Ezagent.Agent.CredentialConnectionTest do
  use ExUnit.Case, async: false

  alias Ezagent.Agent.CredentialConnection
  alias Ezagent.AgentFlavorRegistry

  defmodule PtyTemplate do
    def credential_connection(_opts), do: {:pty, "Sign in to Codex"}
  end

  defmodule ApiKeyTemplate do
    def credential_connection(_opts), do: {:api_key, "openai", "OpenAI API key"}
  end

  defmodule MalformedTemplate do
    def credential_connection(_opts), do: {:pty, 123}
  end

  defmodule CredentiallessTemplate do
  end

  describe "for_flavor/2" do
    test "normalizes a PTY connection declaration" do
      flavor = register(PtyTemplate)

      assert {:ok, {:pty, %{label: "Sign in to Codex"}}} = CredentialConnection.for_flavor(flavor)
    end

    test "normalizes an API-key connection declaration" do
      flavor = register(ApiKeyTemplate)

      assert {:ok, {:api_key, %{provider: "openai", label: "OpenAI API key"}}} =
               CredentialConnection.for_flavor(flavor)
    end

    test "rejects unknown flavors and malformed declarations" do
      malformed_flavor = register(MalformedTemplate)

      assert {:error, :unsupported_connection} =
               CredentialConnection.for_flavor("missing-#{System.unique_integer([:positive])}")

      assert {:error, :unsupported_connection} = CredentialConnection.for_flavor(malformed_flavor)
    end

    test "returns not_required for a credential-less flavor even when it is listed in a role" do
      flavor = register(CredentiallessTemplate)

      assert {:ok, :not_required} =
               CredentialConnection.for_flavor(flavor,
                 roles: [%{role_name: "llm", fill: :agent, flavor: flavor}]
               )
    end
  end

  defp register(template_class) do
    flavor = "credential-connection-#{System.unique_integer([:positive])}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: template_class,
        template_class: template_class
      })

    flavor
  end
end

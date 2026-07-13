defmodule Ezagent.AuthenticationTest do
  use ExUnit.Case, async: false

  alias Ezagent.Authentication
  alias Ezagent.Authentication.BridgeCredential

  defmodule PatResolver do
    def authenticate("esr_pat_v1_ok"), do: {:ok, Ezagent.URI.user("system", "pat-user")}
    def authenticate(_), do: {:error, :invalid_credentials}
  end

  defmodule BridgeResolver do
    def authenticate(%BridgeCredential{token: "bridge-ok", principal: principal}),
      do: {:ok, principal}

    def authenticate(_), do: {:error, :invalid_credentials}
  end

  setup do
    old = Application.get_env(:ezagent_core, Authentication)

    Application.put_env(:ezagent_core, Authentication,
      pat_resolver: PatResolver,
      bridge_resolver: BridgeResolver
    )

    on_exit(fn ->
      if old,
        do: Application.put_env(:ezagent_core, Authentication, old),
        else: Application.delete_env(:ezagent_core, Authentication)
    end)
  end

  test "PAT credential alone resolves the canonical principal" do
    assert {:ok, principal} = Authentication.authenticate("esr_pat_v1_ok")
    assert URI.to_string(principal) == "entity://system/user/pat-user"
  end

  test "bridge credential returns only its connection-bound principal" do
    principal = Ezagent.URI.agent("system", "orchestrator")

    assert {:ok, ^principal} =
             Authentication.authenticate(%BridgeCredential{
               token: "bridge-ok",
               principal: principal
             })
  end

  test "unknown credential types and request-supplied identity maps fail closed" do
    assert {:error, :unsupported_credential} = Authentication.authenticate("opaque")

    assert {:error, :unsupported_credential} =
             Authentication.authenticate(%{token: "esr_pat_v1_ok", principal: "forged"})
  end
end

defmodule Ezagent.Authentication do
  @moduledoc "Unified credential-only authentication boundary."

  alias Ezagent.Authentication.BridgeCredential

  @type result :: {:ok, URI.t()} | {:error, term()}

  @doc "Resolve a credential to its canonical principal without loading capabilities."
  @spec authenticate(term()) :: result()
  def authenticate("esr_pat_v" <> _ = credential), do: resolve(:pat_resolver, credential)

  def authenticate(
        %BridgeCredential{token: token, principal: %URI{scheme: "entity"}} = credential
      )
      when is_binary(token) and token != "" do
    resolve(:bridge_resolver, credential)
  end

  def authenticate(_credential), do: {:error, :unsupported_credential}

  defp resolve(key, credential) do
    with {:ok, resolver} <- resolver(key),
         {:ok, %URI{scheme: "entity"} = principal} <- resolver.authenticate(credential) do
      {:ok, Ezagent.URI.instance(principal)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_credentials}
    end
  end

  defp resolver(key) do
    case :ezagent_core |> Application.get_env(__MODULE__, []) |> Keyword.get(key) do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, {:authentication_resolver_unavailable, key}}
    end
  end
end

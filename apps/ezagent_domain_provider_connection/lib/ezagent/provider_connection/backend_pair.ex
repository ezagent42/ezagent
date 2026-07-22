defmodule Ezagent.ProviderConnection.BackendPair do
  @moduledoc """
  Immutable declaration of one conformance-tested authorization/credential pair.

  Pair identity is stable data. Runtime implementation bindings live outside
  this declaration; no module, process, function, secret state, or
  backend-private reference is stored here.
  """

  @enforce_keys [:pair_id, :authorization_backend, :credential_backend, :fingerprint]
  defstruct @enforce_keys

  @type backend_ref :: %{
          id: String.t(),
          fingerprint: String.t()
        }
  @type t :: %__MODULE__{
          pair_id: String.t(),
          authorization_backend: backend_ref(),
          credential_backend: backend_ref(),
          fingerprint: String.t()
        }

  @doc "Builds a closed backend-pair declaration and derives its fingerprint."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    declaration = %{
      pair_id: fetch_string!(attrs, :pair_id),
      authorization_backend: normalize_backend!(Map.fetch!(attrs, :authorization_backend)),
      credential_backend: normalize_backend!(Map.fetch!(attrs, :credential_backend))
    }

    struct!(__MODULE__, Map.put(declaration, :fingerprint, derive_fingerprint(declaration)))
  end

  @doc false
  @spec verify_fingerprint(t()) :: :ok | {:error, {:declaration_drift, String.t(), String.t()}}
  def verify_fingerprint(%__MODULE__{} = pair) do
    expected =
      pair
      |> Map.from_struct()
      |> Map.delete(:fingerprint)
      |> derive_fingerprint()

    if pair.fingerprint == expected do
      :ok
    else
      {:error, {:declaration_drift, pair.fingerprint, expected}}
    end
  end

  defp normalize_backend!(backend) when is_map(backend) do
    %{
      id: fetch_string!(backend, :id),
      fingerprint: fetch_string!(backend, :fingerprint)
    }
  end

  defp normalize_backend!(_backend),
    do: raise(ArgumentError, "backend reference must be a map")

  defp fetch_string!(attrs, key) do
    case Map.fetch!(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _value -> raise ArgumentError, "#{key} must be a non-empty string"
    end
  end

  defp derive_fingerprint(declaration) do
    declaration
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

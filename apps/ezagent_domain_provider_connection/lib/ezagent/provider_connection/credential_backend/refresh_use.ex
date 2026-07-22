defmodule Ezagent.ProviderConnection.CredentialBackend.RefreshUse do
  @moduledoc """
  Invocation-scoped credential refresh authority.

  This value is opaque, redacted, and must never cross a durable boundary.
  """

  @opaque t :: %__MODULE__{
            authority: pid(),
            token: reference(),
            binding_digest: binary(),
            backend: module(),
            claim_proof: reference() | nil,
            private: term()
          }

  @enforce_keys [:authority, :token, :binding_digest, :backend, :private]
  defstruct @enforce_keys ++ [claim_proof: nil]

  defimpl Inspect do
    def inspect(_use, _opts), do: "#CredentialBackend.RefreshUse<redacted>"
  end

  @doc false
  def new(authority, token, binding_digest, backend, private)
      when is_pid(authority) and is_reference(token) and is_binary(binding_digest) and
             is_atom(backend) do
    %__MODULE__{
      authority: authority,
      token: token,
      binding_digest: binding_digest,
      backend: backend,
      private: private
    }
  end

  @doc false
  def authority(%__MODULE__{authority: authority}), do: authority

  @doc false
  def token(%__MODULE__{token: token}), do: token

  @doc false
  def binding_digest(%__MODULE__{binding_digest: binding_digest}), do: binding_digest

  @doc false
  def backend(%__MODULE__{backend: backend}), do: backend

  @doc false
  def claimed(%__MODULE__{} = use, proof) when is_reference(proof),
    do: %{use | claim_proof: proof}

  @doc false
  def claim_proof(%__MODULE__{claim_proof: proof}), do: proof

  @doc false
  def private(%__MODULE__{private: private}), do: private
end

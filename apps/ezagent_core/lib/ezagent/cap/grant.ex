defmodule Ezagent.Cap.Grant do
  @moduledoc """
  Framework-owned grant-intent freezer and post-verifier issuance site.

  The intent captures the validated target/action/grantee/bounds before any
  Behavior hook runs. Issuance consumes only this frozen value, so argument or
  result rewriting cannot alter the signed authority.

  This is a reviewed-code (Path A) boundary; malicious in-BEAM code is out of
  scope.
  """

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability

  @enforce_keys [:target, :presenter, :grantee, :cap]
  defstruct [:target, :presenter, :grantee, :cap]

  @opaque intent :: %__MODULE__{
            target: URI.t(),
            presenter: URI.t(),
            grantee: URI.t(),
            cap: Capability.t()
          }

  @doc false
  @spec freeze(URI.t(), URI.t(), URI.t(), Capability.t()) :: intent()
  def freeze(%URI{} = target, %URI{} = presenter, %URI{} = grantee, %Capability{} = cap) do
    %__MODULE__{
      target: Ezagent.URI.instance(target),
      presenter: presenter,
      grantee: grantee,
      cap: %{cap | instance: Ezagent.URI.instance(target)}
    }
  end

  @doc false
  @spec issue(Authority.t(), intent()) :: Capability.t()
  def issue(%Authority{} = authority, %__MODULE__{} = intent) do
    artifact = %{
      intent.cap
      | granted_by: intent.presenter,
        granted_at: DateTime.utc_now(),
        grantee_uri: intent.grantee
    }

    Authority.sign(authority, artifact)
  end
end

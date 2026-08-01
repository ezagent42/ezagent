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
  @spec authorize_and_issue_current(
          module() | atom(),
          URI.t(),
          Ezagent.DispatchOrigin.t(),
          map(),
          URI.t(),
          Capability.t()
        ) :: {:ok, Capability.t()} | {:error, term()}
  def authorize_and_issue_current(
        kind,
        %URI{} = target,
        origin,
        ctx,
        %URI{} = grantee,
        %Capability{} = cap
      ) do
    target_instance = Ezagent.URI.instance(target)

    with :ok <- Ezagent.DispatchOrigin.validate(origin, ctx),
         true <-
           match?(%URI{}, cap.instance) and
             Ezagent.URI.stable_key(Ezagent.URI.instance(cap.instance)) ==
               Ezagent.URI.stable_key(target_instance),
         {:ok, _authority_cap} <-
           Ezagent.Cap.Verifier.authorize(
             kind,
             __MODULE__,
             :grant,
             target,
             Map.get(ctx, :authenticated_principal),
             ctx
           ),
         %URI{} = presenter <- Map.get(ctx, :authenticated_principal),
         intent <- freeze(target_instance, presenter, grantee, cap),
         {:ok, issued} <- Authority.issue_current(intent) do
      {:ok, issued}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :grant_target_mismatch}
      _ -> {:error, :invalid_grant_intent}
    end
  end

  @doc false
  @spec issue(Authority.t(), intent()) :: Capability.t() | {:error, :reserved_action}
  def issue(%Authority{}, %__MODULE__{cap: %Capability{action: :self_license}}),
    do: {:error, :reserved_action}

  def issue(%Authority{} = authority, %__MODULE__{} = intent) do
    issue_unchecked(authority, intent)
  end

  @doc false
  @spec issue_self_license(Authority.t(), intent()) ::
          {:ok, Capability.t()} | {:error, :invalid_self_license_intent}
  def issue_self_license(
        %Authority{uri: authority_uri} = authority,
        %__MODULE__{
          target: target,
          presenter: presenter,
          grantee: grantee,
          cap: %Capability{action: :self_license, instance: instance}
        } = intent
      ) do
    if same_uri?(authority_uri, target) and same_uri?(target, presenter) and
         same_uri?(target, grantee) and same_uri?(target, instance) do
      {:ok, issue_unchecked(authority, intent)}
    else
      {:error, :invalid_self_license_intent}
    end
  end

  def issue_self_license(%Authority{}, %__MODULE__{}),
    do: {:error, :invalid_self_license_intent}

  defp issue_unchecked(%Authority{} = authority, %__MODULE__{} = intent) do
    artifact = %{
      intent.cap
      | granted_by: intent.presenter,
        granted_at: DateTime.utc_now(),
        grantee_uri: intent.grantee,
        signing_version: 2,
        grant_id: Ecto.UUID.generate()
    }

    Authority.sign(authority, artifact)
  end

  defp same_uri?(left, right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
end

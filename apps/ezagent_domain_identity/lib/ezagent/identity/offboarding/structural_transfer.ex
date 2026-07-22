defmodule Ezagent.Identity.Offboarding.StructuralTransfer do
  @moduledoc false

  alias Ezagent.Provenance.DerivationEdges

  @default_adapters [
    Module.concat([Ezagent, Workspace, OffboardingAdapter]),
    Module.concat([Ezagent, Session, OffboardingAdapter])
  ]

  @doc false
  @spec transfer(URI.t(), URI.t()) :: :ok | {:error, term()}
  def transfer(%URI{} = resource_uri, %URI{} = deleted_user) do
    case Enum.find(adapters(), &supports?(&1, resource_uri)) do
      nil -> {:error, {:unsupported_structural_descendant, resource_uri}}
      adapter -> apply(adapter, :transfer, [resource_uri, deleted_user])
    end
  rescue
    error -> {:error, {:structural_transfer_failed, resource_uri, error}}
  catch
    kind, reason -> {:error, {:structural_transfer_failed, resource_uri, {kind, reason}}}
  end

  @doc false
  @spec record_transfer(URI.t(), URI.t()) :: :ok | {:error, term()}
  def record_transfer(%URI{} = resource_uri, %URI{} = new_owner) do
    edge_kind = "ownership_transfer:" <> owner_digest(new_owner)

    DerivationEdges.record_derivation_edge(
      resource_uri,
      new_owner,
      edge_kind,
      DerivationEdges.new_attempt_id()
    )
  end

  defp adapters do
    Application.get_env(
      :ezagent_domain_identity,
      :offboarding_structural_transfer_adapters,
      @default_adapters
    )
  end

  defp supports?(adapter, uri) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :supports?, 1) and
      apply(adapter, :supports?, [uri])
  end

  defp owner_digest(owner) do
    owner
    |> Ezagent.URI.stable_key()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

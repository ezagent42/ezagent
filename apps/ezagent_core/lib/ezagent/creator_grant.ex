defmodule Ezagent.CreatorGrant do
  @moduledoc """
  Pure create-time grant policy.

  Creation entries inject business semantics by passing the concrete Kind
  type (`:session`, `:agent`, ...). This module only builds the abstract
  creator-management authority for `Ezagent.ActionSet.Manage`; it does not
  dispatch or mutate Identity state, keeping core free of identity-domain
  dependencies.
  """

  @doc """
  Build the creator's management cap for a newly-created Kind instance.

  `kind` is supplied by the creation path rather than inferred from the URI,
  so each Kind controls its own business semantics while sharing the same
  grant shape.
  """
  @spec manage_cap(atom(), URI.t(), URI.t(), URI.t()) :: Ezagent.Capability.t()
  def manage_cap(kind, %URI{} = instance_uri, %URI{} = workspace_uri, %URI{} = creator_uri)
      when is_atom(kind) do
    %Ezagent.Capability{
      kind: kind,
      behavior: Ezagent.ActionSet.Manage,
      action: :any,
      instance: instance_uri,
      workspace_uri: workspace_uri,
      granted_by: creator_uri,
      granted_at: DateTime.utc_now()
    }
  end

  @doc """
  True when two caps grant the same authority, ignoring provenance metadata.
  """
  @spec same_authority?(Ezagent.Capability.t(), Ezagent.Capability.t()) :: boolean()
  def same_authority?(%Ezagent.Capability{} = left, %Ezagent.Capability{} = right) do
    Ezagent.Capability.identity_key(left) == Ezagent.Capability.identity_key(right)
  end

  def same_authority?(_, _), do: false
end

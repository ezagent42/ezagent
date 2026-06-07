defmodule Ezagent.Agent.CredentialSliceAdapter do
  @moduledoc """
  #17 PR-4 - credential materialization contract for in-process flavors.

  File-backed flavors implement `Ezagent.Agent.CredentialAdapter` and materialize
  credentials into a per-agent config directory. In-process flavors such as curl keep
  their credentials in a persistent Kind slice instead; their Template Class implements
  this contract so the domain create chokepoint can still run the same cascade
  resolution and grant lifecycle before the flavor writes its slice.
  """

  @doc "The persistent slice that receives the resolved credential."
  @callback credential_slice() :: atom()

  @doc """
  Materialize the already-selected credential source into `agent_uri`'s slice.

  `template_data` is the map handed to the Template Class after cascade resolution.
  It must contain the durable `cascade_resolution.credential_source_uri` selected by
  `Ezagent.Credential.Resolver`; the implementation is responsible for using the
  flavor's natural credential shape.
  """
  @callback materialize_credential_slice(URI.t(), map()) :: :ok | {:error, term()}

  @callbacks [
    {:credential_slice, 0},
    {:materialize_credential_slice, 2}
  ]

  @doc "The declarative slice callbacks (all-or-none group)."
  @spec declarative_callbacks() :: [{atom(), non_neg_integer()}]
  def declarative_callbacks, do: @callbacks

  @doc "True iff `class_module` declares the full slice credential adapter."
  @spec credentialled?(module()) :: boolean()
  def credentialled?(class_module) when is_atom(class_module) do
    Code.ensure_loaded(class_module)

    Enum.all?(@callbacks, fn {name, arity} ->
      function_exported?(class_module, name, arity)
    end)
  end
end

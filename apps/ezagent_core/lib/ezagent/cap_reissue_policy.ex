defmodule Ezagent.Cap.ReissuePolicy do
  @moduledoc """
  Domain-owned classification and re-issuance policy for legacy capability artifacts.

  A policy claims only the capability classes owned by its domain. Unknown
  classes are deliberately left unclaimed so the reconciler quarantines them
  instead of inventing authority.
  """

  alias Ezagent.Capability

  @type class :: atom()
  @type action ::
          {:reissue, Ezagent.Cap.authorization()}
          | {:refresh_binding, term()}
          | {:quarantine, term()}

  @callback classify(Capability.t()) :: {:ok, class()} | :not_mine
  @callback reissue_action(Capability.t(), URI.t()) :: action() | {:error, term()}
end

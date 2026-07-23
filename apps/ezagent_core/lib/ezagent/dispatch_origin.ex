defmodule Ezagent.DispatchOrigin do
  @moduledoc """
  Positive provenance stamped by reviewed framework ingress and internal minters.

  `:authenticated_external` means `ctx.authenticated_principal` was fixed from
  an authenticated session or bearer at the transport edge. `ctx.caller` may
  subsequently name reviewed machinery acting for that principal.
  `:trusted_internal` identifies reviewed framework code. An absent or unknown
  stamp fails before capability authorization.

  This is a Path A reviewed-code boundary; malicious code already executing in
  the BEAM is outside the threat model.
  """

  alias Ezagent.Capability

  @type t :: :authenticated_external | :trusted_internal

  @doc false
  @spec validate(t() | nil, map()) :: :ok | {:error, term()}
  def validate(:trusted_internal, _ctx), do: :ok

  def validate(
        :authenticated_external,
        %{authenticated_principal: %URI{} = presenter} = ctx
      ) do
    caps = Map.get(ctx, :caps, MapSet.new()) || MapSet.new()

    if Enum.all?(caps, &presented_by?(&1, presenter)) do
      :ok
    else
      {:error, :presenter_mismatch}
    end
  end

  def validate(:authenticated_external, _ctx), do: {:error, :unauthenticated_presenter}
  def validate(_origin, _ctx), do: {:error, :unstamped_origin}

  defp presented_by?(%Capability{grantee_uri: presenter}, presenter), do: true
  defp presented_by?(_cap, _presenter), do: false
end

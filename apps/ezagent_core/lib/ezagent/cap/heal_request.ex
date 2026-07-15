defmodule Ezagent.Cap.HealRequest do
  @moduledoc """
  Durable, allowlisted payload for one exact-artifact capability heal.

  `expected` is the byte-identical CAS token captured by the planner. `action`
  is supplied by the owning domain policy and is executed only after the target
  entity reaches ready.
  """

  @enforce_keys [:expected, :class, :action]
  defstruct [:expected, :class, :action]

  @type t :: %__MODULE__{
          expected: Ezagent.Capability.t(),
          class: atom(),
          action: Ezagent.Cap.ReissuePolicy.action()
        }

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{expected: %Ezagent.Capability{}, class: class, action: action})
      when is_atom(class) do
    valid_action?(action)
  end

  def valid?(_request), do: false

  defp valid_action?({:reissue, authorization}) do
    match?({:held_by, %URI{}}, authorization) or
      match?({:admin, %URI{}}, authorization) or
      match?({:rule, rule, %URI{}} when is_atom(rule), authorization) or
      match?({:genesis, %URI{}}, authorization)
  end

  defp valid_action?({:refresh_binding, ref}), do: is_map(ref) or is_tuple(ref)
  defp valid_action?({:quarantine, _reason}), do: true
  defp valid_action?(_action), do: false
end

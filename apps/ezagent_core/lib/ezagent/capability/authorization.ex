defmodule Ezagent.Capability.Authorization do
  @moduledoc "Shared provenance-aware full-capability predicate for runtime and preflights."

  alias Ezagent.Capability

  @doc "Return the first provenance-valid held capability matching a full needed-cap shape."
  @spec authorizing_cap(MapSet.t(Capability.t()) | [Capability.t()] | term(), map()) ::
          {:ok, Capability.t()} | :error
  def authorizing_cap(caps, needed) when is_struct(caps, MapSet) or is_list(caps) do
    Enum.find_value(caps, :error, fn
      %Capability{} = cap ->
        if Capability.granted_by_entity?(cap) and safe_matches?(cap, needed),
          do: {:ok, cap},
          else: false

      _ ->
        false
    end)
  end

  def authorizing_cap(_caps, _needed), do: :error

  @doc "Whether a provenance-valid held capability matches a full needed-cap shape."
  @spec authorizes?(MapSet.t(Capability.t()) | [Capability.t()] | term(), map()) :: boolean()
  def authorizes?(caps, needed),
    do: match?({:ok, %Capability{}}, authorizing_cap(caps, needed))

  defp safe_matches?(cap, needed) do
    Capability.matches?(cap, needed)
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end

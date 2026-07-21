defmodule Ezagent.Capability.Authorization do
  @moduledoc "Shared provenance-aware full-capability predicate for runtime and preflights."

  alias Ezagent.Capability

  @doc "Return the first provenance-valid held capability matching a full needed-cap shape."
  @spec authorizing_cap(URI.t(), MapSet.t(Capability.t()) | [Capability.t()] | term(), map()) ::
          {:ok, Capability.t()} | :error
  def authorizing_cap(%URI{} = holder, caps, needed)
      when is_struct(caps, MapSet) or is_list(caps) do
    Enum.find_value(caps, :error, fn
      %Capability{} = cap ->
        if Capability.granted_by_entity?(cap) do
          case Ezagent.Cap.authorize(holder, [cap], needed) do
            {:ok, %Capability{} = authorized} -> {:ok, authorized}
            {:error, _reason} -> false
          end
        else
          false
        end

      _ ->
        false
    end)
  end

  def authorizing_cap(_holder, _caps, _needed), do: :error

  @doc "Whether a provenance-valid held capability matches a full needed-cap shape."
  @spec authorizes?(URI.t(), MapSet.t(Capability.t()) | [Capability.t()] | term(), map()) ::
          boolean()
  def authorizes?(%URI{} = holder, caps, needed),
    do: match?({:ok, %Capability{}}, authorizing_cap(holder, caps, needed))

  def authorizes?(_holder, _caps, _needed), do: false
end

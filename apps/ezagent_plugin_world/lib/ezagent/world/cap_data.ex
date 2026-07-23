defmodule Ezagent.World.CapData do
  @moduledoc """
  Shared capability row builders for world identity detail surfaces.
  """

  @doc "Read and render granted capability rows for an entity detail surface."
  @spec list_entity_caps(URI.t() | term(), URI.t() | nil, MapSet.t()) :: [map()] | map()
  def list_entity_caps(%URI{} = entity_uri, caller_uri, caller_caps) do
    case Ezagent.Domain.Agent.read_caps(entity_uri, %{
           caller: caller_uri,
           authenticated_principal: caller_uri,
           caps: caller_caps
         }) do
      {:ok, caps} -> Enum.map(caps, &cap_row/1)
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  rescue
    err -> %{"error" => inspect(err)}
  end

  def list_entity_caps(_entity_uri, _caller_uri, _caller_caps),
    do: %{"error" => "invalid_entity"}

  defp cap_row(cap) do
    %{
      "kind" => inspect(cap.kind),
      "behavior" => inspect(cap.behavior),
      "action" => inspect(Ezagent.Capability.action_of(cap)),
      "instance" => instance_scope_display(cap.instance),
      "workspace_uri" => encode_uri(cap.workspace_uri),
      "granted_by" => encode_uri(cap.granted_by)
    }
  end

  defp instance_scope_display(%URI{} = uri), do: encode_uri(uri)
  defp instance_scope_display(:any), do: "any"

  defp instance_scope_display({tag, %URI{} = uri}) when is_atom(tag),
    do: "#{tag} #{encode_uri(uri)}"

  defp instance_scope_display(other), do: inspect(other)

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil
end

defmodule Ezagent.World.ConversationMessages do
  @moduledoc false

  @doc false
  @spec parse_mentions(String.t(), [map()]) :: [URI.t()]
  def parse_mentions(text, members), do: parse_mentions(text, members, [])

  @doc false
  @spec parse_mentions(String.t(), [map()], [map() | String.t()]) :: [URI.t()]
  def parse_mentions(text, members, open_role_slots)
      when is_binary(text) and is_list(members) and is_list(open_role_slots) do
    (parse_uri_mentions(text) ++ parse_bare_mentions(text, members, open_role_slots))
    |> Enum.uniq_by(&URI.to_string/1)
  end

  def parse_mentions(_text, _members, _open_role_slots), do: []

  defp parse_uri_mentions(text) do
    ~r/@(entity:\/\/[^\s]+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(&safe_uri/1)
  end

  defp parse_bare_mentions(_text, [], _open_role_slots), do: []

  defp parse_bare_mentions(text, members, open_role_slots) do
    ~r/(?<![\p{L}\p{N}_])@([A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(&resolve_member_token(&1, members, open_role_slots))
  end

  defp resolve_member_token(name, members, open_role_slots) do
    case resolve_member_name(name, members) do
      [] -> maybe_resolve_colon_head(name, members, open_role_slots)
      uris -> uris
    end
  end

  defp maybe_resolve_colon_head(name, members, open_role_slots) do
    case String.split(name, ":", parts: 2) do
      [head, _tail] ->
        if colon_role_name_present?(members, open_role_slots) do
          []
        else
          resolve_member_name(head, members)
        end

      _other ->
        []
    end
  end

  defp colon_role_name_present?(members, open_role_slots) do
    members
    |> Enum.map(&Map.get(&1, "role_name"))
    |> Kernel.++(Enum.map(open_role_slots, &role_name_value/1))
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, ":")))
  end

  defp role_name_value(%{"role_name" => role_name}), do: role_name
  defp role_name_value(%{role_name: role_name}), do: role_name
  defp role_name_value(role_name) when is_binary(role_name), do: role_name
  defp role_name_value(_role_name), do: nil

  defp resolve_member_name(name, members) do
    [
      Enum.filter(members, &(uri_path_segment(Map.get(&1, "uri")) == name)),
      Enum.filter(members, &(Map.get(&1, "role_name") == name)),
      Enum.filter(members, &(Map.get(&1, "display_name") == name))
    ]
    |> Enum.reduce_while([], fn
      [], acc -> {:cont, acc}
      candidates, _acc -> {:halt, unique_candidate_uri(candidates)}
    end)
  end

  defp unique_candidate_uri(candidates) do
    case candidates |> Enum.map(&Map.get(&1, "uri")) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [uri_string] -> safe_uri(uri_string)
      _other -> []
    end
  end

  defp uri_path_segment(uri_string) when is_binary(uri_string) do
    case Ezagent.URI.parse(uri_string) do
      {:ok, %URI{} = uri} ->
        case Ezagent.URI.name(uri) do
          {:ok, name} -> name
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp uri_path_segment(_uri), do: nil

  defp safe_uri(uri_string) do
    case Ezagent.URI.parse(uri_string) do
      {:ok, %URI{} = uri} -> [uri]
      _other -> []
    end
  end
end

defmodule Ezagent.World.ConversationRoutingForm do
  @moduledoc false

  @doc false
  def build_matcher(params) when is_map(params) do
    type = Map.get(params, "matcher_type")
    arg = Map.get(params, "matcher_arg")

    case {type, arg} do
      {"mention", text} when is_binary(text) and text != "" ->
        {:ok, Ezagent.Routing.Matcher.mention(text)}

      {"from", text} when is_binary(text) and text != "" ->
        {:ok, Ezagent.Routing.Matcher.from(text)}

      {"from_role", text} when is_binary(text) and text != "" ->
        build_from_role_matcher(text)

      {"text_contains", text} when is_binary(text) and text != "" ->
        {:ok, Ezagent.Routing.Matcher.text_contains(text)}

      {"always", _} ->
        {:ok, Ezagent.Routing.Matcher.always()}

      _ ->
        {:error, :invalid_matcher_form}
    end
  end

  def build_matcher(_), do: {:error, :invalid_matcher_form}

  defp build_from_role_matcher(text) do
    role_name = String.trim(text)

    if valid_role_name?(role_name) do
      {:ok, Ezagent.Routing.Matcher.from_role(role_name)}
    else
      {:error, :invalid_matcher_form}
    end
  end

  @doc false
  def parse_receivers(value) do
    values =
      cond do
        is_list(value) -> value
        is_binary(value) -> String.split(value, ",", trim: true)
        true -> []
      end

    values
    |> Enum.map(&parse_receiver/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def revalidate_matcher_arg(socket, %{
        "matcher_type" => type,
        "matcher_arg" => arg
      })
      when type in ["mention", "from"] and is_binary(arg) and arg != "" do
    revalidate_uris(socket, [arg], [:entity])
  end

  def revalidate_matcher_arg(_socket, _params), do: :ok

  @doc false
  def revalidate_receivers(socket, receivers) do
    Enum.reduce_while(receivers, :ok, fn receiver, :ok ->
      case receiver do
        {:role, role_name} when is_binary(role_name) ->
          if valid_role_name?(role_name),
            do: {:cont, :ok},
            else: {:halt, {:error, {:invalid_role, role_name}}}

        receiver when is_binary(receiver) ->
          if Ezagent.Routing.Resolver.magic_token?(receiver) do
            {:cont, :ok}
          else
            case revalidate_uris(socket, [receiver], [:entity, :session]) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end
      end
    end)
  end

  @doc false
  def revalidate_uris(socket, uris, kinds) do
    caller_uri = socket.assigns.current_entity_uri
    workspace_uri = socket.assigns.current_workspace_uri

    Enum.reduce_while(uris, :ok, fn uri, :ok ->
      if uri_options_valid_for?(caller_uri, workspace_uri, uri, kinds) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_uri, uri}}}
      end
    end)
  end

  @doc false
  def uri_options_valid_for?(caller_uri, workspace_uri, uri, kinds) do
    Module.concat([Ezagent.UI, UriOptions])
    |> apply(:valid_for?, [caller_uri, workspace_uri, uri, kinds])
  rescue
    _ -> false
  end

  @doc false
  def wrap_in_session(matcher, %URI{} = session_uri) do
    case matcher do
      {:in_session, _} ->
        matcher

      leaf ->
        Ezagent.Routing.Matcher.all_of([
          Ezagent.Routing.Matcher.in_session(session_uri),
          leaf
        ])
    end
  end

  defp parse_receiver(value) do
    text = String.trim(to_string(value))

    cond do
      text == "" ->
        nil

      String.starts_with?(text, "role:") ->
        text
        |> String.trim_leading("role:")
        |> String.trim()
        |> role_receiver()

      true ->
        text
    end
  end

  defp role_receiver(""), do: nil
  defp role_receiver(role_name), do: Ezagent.Routing.Receiver.role(role_name)

  defp valid_role_name?(role_name) when is_binary(role_name) do
    role_name != "" and Regex.match?(~r/^[A-Za-z0-9_.-]+$/, role_name)
  end
end

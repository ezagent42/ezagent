defmodule EzagentPluginCustomerChat.Theme do
  @moduledoc """
  Per-tenant customer-chat theme. Config-driven — NO hardcoded tenant
  data (migration constraint #1). Resolution order (later wins):
    1. built-in defaults
    2. `priv/customer_chat_themes/<tenant>.json` fixture (if present)
    3. `config :ezagent_plugin_customer_chat, :customer_chat_themes` map (prod override)
  """

  @type t :: %{
          title: String.t(),
          primary_color: String.t(),
          welcome_message: String.t(),
          placeholder: String.t(),
          logo_url: String.t() | nil
        }

  @keys [:title, :primary_color, :welcome_message, :placeholder, :logo_url]

  @spec for_tenant(String.t()) :: t()
  def for_tenant(tenant) when is_binary(tenant) do
    defaults(tenant)
    |> deep_put(file_theme(tenant))
    |> deep_put(config_theme(tenant))
  end

  defp defaults(tenant) do
    %{
      title: tenant,
      primary_color: "#2563eb",
      welcome_message: "Hi! How can I help you today?",
      placeholder: "Type your message…",
      logo_url: nil
    }
  end

  defp file_theme(tenant) do
    path = Path.join(:code.priv_dir(:ezagent_plugin_customer_chat), "customer_chat_themes/#{tenant}.json")

    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp config_theme(tenant) do
    :ezagent_plugin_customer_chat
    |> Application.get_env(:customer_chat_themes, %{})
    |> Map.get(tenant, %{})
  end

  # merge a string-or-atom-keyed override map onto an atom-keyed base,
  # ignoring nil values and unknown keys
  defp deep_put(base, override) when is_map(override) do
    Enum.reduce(@keys, base, fn key, acc ->
      case fetch(override, key) do
        {:ok, val} when not is_nil(val) -> Map.put(acc, key, val)
        _ -> acc
      end
    end)
  end

  defp fetch(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end
end

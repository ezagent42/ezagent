defmodule Ezagent.PluginCc.Template.CcAgent.ConfigSchema do
  @moduledoc false

  @doc false
  def fields do
    [
      %{
        key: "model",
        type: :string,
        label: "Model",
        placeholder: "claude-sonnet-4-6",
        help: "Example: claude-sonnet-4-6; leave blank for Claude Code default"
      },
      %{
        key: "effort",
        type: :enum,
        label: "Effort",
        options:
          Application.get_env(:ezagent_plugin_cc, :effort_options, [
            "default",
            "low",
            "medium",
            "high"
          ])
      },
      %{
        key: "permission_mode",
        type: :enum,
        label: "Permission mode",
        options:
          Application.get_env(:ezagent_plugin_cc, :permission_mode_options, [
            "default",
            "acceptEdits",
            "bypassPermissions",
            "plan"
          ]),
        default: "default"
      },
      %{key: "tools", type: :list, label: "Tools"}
    ]
  end

  @doc false
  def validate_values(tmpl) when is_map(tmpl) do
    with :ok <- check_optional_non_empty_string(tmpl, "model"),
         :ok <- check_optional_enum(tmpl, "effort", option_values("effort")),
         :ok <- check_optional_enum(tmpl, "permission_mode", option_values("permission_mode")),
         :ok <- check_optional_tools(tmpl) do
      :ok
    end
  end

  defp option_values(key) do
    fields()
    |> Enum.find_value([], fn
      %{key: ^key, options: options} -> options
      _ -> nil
    end)
  end

  defp check_optional_non_empty_string(tmpl, key) do
    case Map.fetch(tmpl, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) and value != "" -> :ok
      {:ok, bad} -> {:error, {:invalid_config_field, key, bad}}
    end
  end

  defp check_optional_enum(tmpl, key, allowed) do
    case Map.fetch(tmpl, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> check_enum_value(key, value, allowed)
      {:ok, bad} -> {:error, {:invalid_config_field, key, bad}}
    end
  end

  defp check_enum_value(key, value, allowed) do
    if value in allowed, do: :ok, else: {:error, {:invalid_config_field, key, value}}
  end

  defp check_optional_tools(tmpl) do
    case Map.fetch(tmpl, "tools") do
      :error -> :ok
      {:ok, tools} when is_list(tools) -> check_tool_values(tools)
      {:ok, bad} -> {:error, {:invalid_config_field, "tools", bad}}
    end
  end

  defp check_tool_values(tools) do
    if Enum.all?(tools, &(is_binary(&1) and &1 != "")) do
      :ok
    else
      {:error, {:invalid_config_field, "tools", tools}}
    end
  end
end

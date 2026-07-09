defmodule Ezagent.PluginCodex.Template.CodexAgent.ConfigSchema do
  @moduledoc false

  @doc false
  def fields do
    [
      %{
        key: "model",
        type: :string,
        label: "Model",
        placeholder: "leave blank for Codex default",
        help: "Optional; accepts a custom Codex model id"
      },
      %{
        key: "approval_policy",
        type: :enum,
        label: "Approval policy",
        options:
          Application.get_env(:ezagent_plugin_codex, :approval_policy_options, [
            "never",
            "on-request",
            "untrusted"
          ])
      },
      %{
        key: "sandbox",
        type: :enum,
        label: "Sandbox",
        options:
          Application.get_env(:ezagent_plugin_codex, :sandbox_options, [
            "read-only",
            "workspace-write",
            "danger-full-access"
          ])
      }
    ]
  end

  @doc false
  def validate_values(tmpl) when is_map(tmpl) do
    with :ok <- check_optional_string(tmpl, "model"),
         :ok <- check_optional_enum(tmpl, "approval_policy", option_values("approval_policy")),
         :ok <- check_optional_enum(tmpl, "sandbox", option_values("sandbox")) do
      :ok
    end
  end

  defp check_optional_string(tmpl, key) do
    case Map.fetch(tmpl, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, bad} -> {:error, {:invalid_string_field, key, bad}}
    end
  end

  defp check_optional_enum(tmpl, key, allowed) do
    case Map.fetch(tmpl, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> check_enum_value(key, value, allowed)
      {:ok, bad} -> {:error, {:invalid_string_field, key, bad}}
    end
  end

  defp check_enum_value(key, value, allowed) do
    if value in allowed, do: :ok, else: {:error, {:invalid_enum_field, key, value}}
  end

  defp option_values(key) do
    fields()
    |> Enum.find_value([], fn
      %{key: ^key, options: options} -> options
      _ -> nil
    end)
  end
end

defmodule Ezagent.TestSupport.NoopAgentTemplate do
  @moduledoc false

  @behaviour Ezagent.Kind.Template

  @impl Ezagent.Kind.Template
  def template_name, do: "test.noop_agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def template_data_extra(_content), do: %{}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, _workspace_uri) do
    agent_uri = Ezagent.URI.new!(uri_str)

    with :ok <- validate(tmpl) do
      case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], meta(tmpl, true)}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  defp check_class(%{"class" => "test.noop_agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    try do
      uri = Ezagent.URI.new!(uri_str)

      if uri.scheme == "entity" and Ezagent.URI.type?(uri, :agent) do
        :ok
      else
        {:error, {:bad_agent_uri, uri_str}}
      end
    rescue
      ArgumentError -> {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  defp meta(tmpl, fresh?) do
    %{
      fresh?: fresh?,
      config_dir_path: nil,
      respawn_template_data: tmpl
    }
  end
end

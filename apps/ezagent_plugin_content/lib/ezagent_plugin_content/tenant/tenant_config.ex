defmodule EzagentPluginContent.Tenant.TenantConfig do
  @moduledoc """
  Read tenant configuration from ConfigStore.
  Thin wrapper over Ezagent.Socialware.ConfigStore.resolve/4.
  """

  @doc """
  Read a tenant's configuration from ConfigStore.
  Returns `{:ok, body_map}` or `:none`.
  """
  @spec read_config(String.t()) :: {:ok, map()} | :none
  def read_config(tid) do
    case Ezagent.Socialware.ConfigStore.resolve(
           "workspace",
           "workspace://#{tid}",
           "entity://system/tenant-config",
           "tenant:#{tid}:config"
         ) do
      {:ok, config_object} -> {:ok, config_object.body}
      :none -> :none
    end
  end

  @doc """
  Read a tenant's active CR.
  Returns `{:ok, body_map}` or `:none`.
  """
  @spec read_cr(String.t(), String.t()) :: {:ok, map()} | :none
  def read_cr(tid, cr_id) do
    case Ezagent.Socialware.ConfigStore.resolve(
           "workspace",
           "workspace://#{tid}",
           "entity://system/cr",
           "cr:#{tid}:#{cr_id}"
         ) do
      {:ok, config_object} -> {:ok, config_object.body}
      :none -> :none
    end
  end

  @doc """
  Update an existing CR's body via ConfigStore.write_and_point.
  """
  @spec update_cr(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_cr(tid, cr_id, body) do
    Ezagent.Socialware.ConfigStore.write_and_point(%{
      layer: "workspace",
      workspace_uri: "workspace://#{tid}",
      subject_uri: "entity://system/cr",
      key: "cr:#{tid}:#{cr_id}",
      body: body,
      actor_uri: "system://cr-engine",
      source_turn_id: "update_#{System.unique_integer([:monotonic])}"
    })
    |> case do
      {:ok, _} -> {:ok, body}
      e -> e
    end
  end
end

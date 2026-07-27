defmodule EzagentDomainAgent.TestSupport.PreStartTemplateClass do
  @moduledoc false

  @behaviour Ezagent.Kind.Template

  @impl true
  def template_name, do: "test.pre_start_agent"

  @impl true
  def validate(_data), do: :ok

  @impl true
  def template_data_extra(_content), do: %{}

  @impl true
  def instantiate(_name, data, _workspace_uri) do
    instantiate_with_opts(data)
  end

  @impl true
  def instantiate(_name, data, _workspace_uri, launch_context: _launch_context) do
    instantiate_with_opts(data)
  end

  defp instantiate_with_opts(data) do
    owner = Application.fetch_env!(:ezagent_domain_agent, :pre_start_test_owner)
    agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))

    # #201 PR-2 — instantiate-time flavor reads come from the data map
    # (authored by `AgentTemplate.to_template_data/2`), NEVER the global
    # `AgentFlavorAttributes` ETS table, which is no longer written before
    # the spawn winner is known.
    flavor_read =
      case Map.get(data, "flavor") do
        flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
        _ -> :none
      end

    send(owner, {:flavor_during_instantiate, flavor_read})
    send(owner, {:instantiate_called, data})

    case Application.get_env(:ezagent_domain_agent, :pre_start_test_mode, :success) do
      :success ->
        {:ok, [agent_uri], %{fresh?: false}}

      :claimed_fresh ->
        {:ok, [agent_uri], %{fresh?: true}}

      :error ->
        {:error, :instantiate_failed}

      :raise ->
        raise "instantiate raised"

      :exit ->
        exit(:instantiate_exited)
    end
  end
end

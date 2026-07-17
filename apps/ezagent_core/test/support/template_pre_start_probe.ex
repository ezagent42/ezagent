defmodule Ezagent.TestSupport.TemplatePreStartProbe do
  @moduledoc false

  @behaviour Ezagent.Kind.Template.PreStart

  @impl true
  def prepare(reference) do
    owner = Application.fetch_env!(:ezagent_core, :template_pre_start_test_owner)
    send(owner, {:pre_start_prepare, reference})

    case Application.fetch_env!(:ezagent_core, :template_pre_start_prepare_result) do
      callback when is_function(callback, 0) -> callback.()
      result -> result
    end
  end

  @impl true
  def complete(claim, outcome) do
    owner = Application.fetch_env!(:ezagent_core, :template_pre_start_test_owner)
    send(owner, {:pre_start_complete, claim, outcome})

    case Application.get_env(:ezagent_core, :template_pre_start_complete_result, :ok) do
      callback when is_function(callback, 0) -> callback.()
      result -> result
    end
  end
end

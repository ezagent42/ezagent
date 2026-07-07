defmodule Ezagent.Socialware.ManifestViews do
  @moduledoc false

  @doc false
  @spec session_view_registry() :: {:ok, module()} | :error
  def session_view_registry do
    module = Module.concat([Ezagent, UI, SessionViewRegistry])

    if Code.ensure_loaded?(module) and function_exported?(module, :table, 0) and
         function_exported?(module, :init, 0) do
      {:ok, module}
    else
      :error
    end
  end
end

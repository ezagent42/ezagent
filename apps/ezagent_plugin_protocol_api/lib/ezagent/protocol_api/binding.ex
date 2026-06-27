defmodule Ezagent.ProtocolApi.Binding do
  @moduledoc """
  LLM Protocol API no-op Binding — P0 stub.

  The REAL transport is the HTTP response in
  `EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug`.
  This module exists solely to satisfy the Grill-5 compile check.
  P1 will introduce the request-scoped binding variant.
  """

  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: Ezagent.ProtocolApi.Adapter

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def publish(_payload, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end

defmodule EzagentPluginLoom.Tools.Echo do
  @moduledoc """
  Smoke-test tool: returns the args verbatim.

  Useful for verifying the tool RPC plumbing end-to-end without
  needing external network or credentials. The AI is told this exists
  via `ToolRegistry.prompt_block/0` so a page can `await platform.tool(
  "echo", {text: "hello"})` and see `{ok: true, result: {text: "hello"}}`.
  """

  @behaviour EzagentPluginLoom.Tool

  @impl true
  def name, do: "echo"

  @impl true
  def description, do: "返回 args 原样回声(烟测用,无副作用)"

  @impl true
  def args_schema do
    %{
      "text" => %{type: "string", required: false, doc: "任意文本,会原样回来"}
    }
  end

  @impl true
  def call(args, _ctx) when is_map(args), do: {:ok, args}
  def call(_args, _ctx), do: {:error, :bad_args}
end

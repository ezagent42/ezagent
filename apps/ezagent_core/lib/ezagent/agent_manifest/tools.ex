defmodule Ezagent.AgentManifest.Tools do
  @moduledoc """
  Dispatch-backed runtime for manifest-declared tools.

  Manifest caps are declarations only. Tool dispatch always carries an empty
  `ctx.caps` set so authorization falls through to `holds_cap?/2` against the
  agent's Identity slice.
  """

  alias Ezagent.Invocation

  @doc """
  Dispatch a manifest-declared action tool as `agent_uri` with empty `ctx.caps`.
  """
  @spec dispatch_action(URI.t(), map(), map(), keyword()) :: term()
  def dispatch_action(agent_uri, tool, args, opts \\ [])

  def dispatch_action(%URI{} = agent_uri, %{type: :action, action: action}, args, opts)
      when is_binary(action) and is_map(args) and is_list(opts) do
    dispatch_fun = Keyword.get(opts, :dispatch_fun, &Invocation.dispatch/1)
    target = Ezagent.URI.new!(action)

    dispatch_fun.(%Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: agent_uri,
        authenticated_principal: agent_uri,
        caps: MapSet.new(),
        reply: {:caller_inbox, self()}
      },
      origin: :trusted_internal
    })
  end

  def dispatch_action(%URI{}, %{type: type}, _args, _opts),
    do: {:error, {:unsupported_tool_type, type}}

  def dispatch_action(_, _, _, _), do: {:error, :invalid_tool_dispatch_args}
end

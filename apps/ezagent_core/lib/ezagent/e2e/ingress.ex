defmodule Ezagent.E2E.Ingress do
  @moduledoc """
  #21 PR-2 — drive an **ingress step** through the REAL Feishu ingress dispatcher
  (`EzagentPluginFeishu.InboundDispatcher.dispatch/1`), which exercises sender resolution,
  chat-binding disambiguation, presence, session rehydrate, legend-aware mention parsing,
  and human-facing error reporting (codex r1: `Invocation.dispatch` alone is NOT the
  user-facing path). The ONLY thing tier 1 doesn't cover vs tier 2 is the raw WS frame.

  The dispatcher lives in the feishu PLUGIN; core must not compile-depend on a plugin, so
  it is **late-bound** by atom module + `apply/3` (overridable via `:dispatcher` for tests).
  """

  @inbound :"Elixir.EzagentPluginFeishu.InboundDispatcher"

  @doc """
  Feed a decoded Feishu inbound event to the real dispatcher.

  `opts` is the dispatcher keyword list: `:chat_id` (required), `:sender` (required map),
  `:text`, `:mentions`, `:message_id`. Test-only `:dispatcher` overrides the target module.
  Returns the dispatcher's result, or `{:error, {:inbound_dispatcher_unavailable, mod}}` if
  the feishu plugin isn't loaded.
  """
  @spec feishu(keyword()) :: term()
  def feishu(opts) when is_list(opts) do
    mod = Keyword.get(opts, :dispatcher, @inbound)
    dispatch_opts = Keyword.drop(opts, [:dispatcher])

    if Code.ensure_loaded?(mod) and function_exported?(mod, :dispatch, 1) do
      apply(mod, :dispatch, [dispatch_opts])
    else
      {:error, {:inbound_dispatcher_unavailable, mod}}
    end
  end
end

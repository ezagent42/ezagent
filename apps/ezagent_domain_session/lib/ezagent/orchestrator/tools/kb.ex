defmodule Ezagent.Orchestrator.Tools.Kb do
  @moduledoc false
  # KB orchestrator tools (kb-retrieval SPEC §5.3 option 1 — bridge-token /
  # orchestrator authority). Extracted into its own submodule (mirrors
  # `Tools.Participants` / `Tools.Templates`) so `tools.ex` stays under the
  # `oversized_modules_gt_1000` + `def_count_orchestrator_tools` arch gates.
  #
  # Each tool dispatches `kb.query` / `kb.ingest` into a `kb`×native agent NAMED
  # within the orchestrator's OWN workspace, carrying the ORCHESTRATOR's
  # reconstructed caps (option 1; the caller-caps model is the deferred option 2,
  # §9.6). The target is never a caller-supplied cross-workspace URI — dispatch
  # enforces same-workspace.

  alias Ezagent.Invocation
  alias Ezagent.Orchestrator.Tools

  @doc """
  `kb.query` MCP tool — retrieve top-k chunks from a `kb`-agent in the
  orchestrator's workspace. Required `opts`: `:caller`, `:caps`,
  `:workspace_uri`.
  """
  @spec kb_query(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def kb_query(kb_agent, query, k, opts \\ [])
      when is_binary(kb_agent) and is_binary(query) and is_integer(k) and k > 0 do
    dispatch_kb(kb_agent, :query, %{query: query, k: k}, opts)
  end

  @doc """
  `kb.ingest` MCP tool — ingest one source document into a `kb`-agent in the
  orchestrator's workspace. Required `opts`: `:caller`, `:caps`,
  `:workspace_uri`.
  """
  @spec kb_ingest(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def kb_ingest(kb_agent, source_uri, opts \\ [])
      when is_binary(kb_agent) and is_binary(source_uri) do
    dispatch_kb(kb_agent, :ingest, %{source_uri: source_uri}, opts)
  end

  defp dispatch_kb(kb_agent, action, args, opts) do
    with {:ok, caller} <- Tools.require_opt(opts, :caller),
         {:ok, caps} <- Tools.require_opt(opts, :caps),
         {:ok, workspace_uri} <- Tools.require_opt(opts, :workspace_uri),
         {:ok, agent_uri} <- kb_agent_uri(workspace_uri, kb_agent) do
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(agent_uri, :kb, action),
        mode: :call,
        args: args,
        ctx: %{caller: caller, caps: Tools.to_cap_set(caps), reply: {:caller_inbox, self()}}
      })
    end
  end

  # Build the kb-agent URI in the orchestrator's OWN workspace (never a
  # caller-named cross-workspace target — dispatch also enforces same-workspace).
  defp kb_agent_uri(%URI{} = workspace_uri, kb_agent) do
    ws = Ezagent.URI.workspace_name!(workspace_uri)
    {:ok, Ezagent.URI.agent(ws, kb_agent)}
  rescue
    _ -> {:error, {:invalid_kb_agent, kb_agent}}
  end
end

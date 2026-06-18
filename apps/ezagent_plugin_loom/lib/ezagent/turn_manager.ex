defmodule Ezagent.PluginLoom.TurnManager do
  @moduledoc """
  Drives the substrate authoring loop for a loom socialware vertical session
  (P1). This is the re-expression of the legacy `LoomOrchestrator`'s brain onto
  `Ezagent.Behavior.Turn` + `Ezagent.Behavior.Surface`:

      open → compose([%{kind: :chat, text}, %{kind: :page, tree}]) → settle

  `compose` emits `Surface.put_version`; `settle` defers `approve` +
  `commit_settlement` (→ customer delivery). The page generation itself is
  INJECTED (`generator`), so the substrate wiring is testable with a stub and
  the real LLM codegen (builder) plugs in unchanged. See
  `docs/loom-port/SOCIALWARE-VERTICAL.md`.

  ## Caps

  Drives every `turn.*`/`surface.*` action with ONE production-blessed
  within-session cap (`kind: :session, behavior: :any, action: :any,
  instance: {:within_session, session_uri}`) — the same shape the session
  orchestrator is granted (`entity/session/orchestrator/caps.ex`). NOT
  `system://bootstrap` (that's admin/test authority). The `caller` is the
  session's manager/orchestrator URI.
  """

  alias Ezagent.{Capability, Invocation}

  @type gen_result :: %{required(:tree) => map(), optional(:reply) => String.t()}

  @doc """
  Run one authoring turn: generate the page from `request`, then drive the
  substrate turn so the page lands as a new approved `Surface` version.

  `generator` is `(request -> {:ok, gen_result} | {:error, term})` where
  `gen_result` carries `:tree` (the page, an opaque files/render map) and an
  optional `:reply` (a customer-visible chat line).
  """
  @spec build_page(URI.t(), URI.t(), term(), (term() -> {:ok, gen_result()} | {:error, term()})) ::
          {:ok, %{turn_id: String.t()}} | {:error, term()}
  def build_page(%URI{} = session_uri, %URI{} = manager_uri, request, generator)
      when is_function(generator, 1) do
    with {:ok, %{tree: tree} = gen} <- generator.(request) do
      caps = within_session_caps(session_uri)
      reply = gen |> Map.get(:reply, "") |> to_string()

      with {:ok, %{turn_id: turn_id}} <-
             drive(session_uri, manager_uri, caps, :turn, :open, %{
               trigger: %{request: safe_string(request)},
               opened_at: System.system_time(:millisecond)
             }),
           {:ok, _composed} <-
             drive(session_uri, manager_uri, caps, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: compose_refs(reply, tree)
             }),
           {:ok, %{status: :settled}} <-
             drive(session_uri, manager_uri, caps, :turn, :settle, %{turn_id: turn_id}) do
        {:ok, %{turn_id: turn_id}}
      end
    end
  end

  @doc "The within-session driving cap set for a loom session (production cap shape)."
  @spec within_session_caps(URI.t()) :: MapSet.t()
  def within_session_caps(%URI{} = session_uri) do
    MapSet.new([
      Capability.cap(
        :session,
        :any,
        :any,
        {:within_session, session_uri},
        Capability.workspace_of(session_uri)
      )
    ])
  end

  defp compose_refs(reply, tree) do
    chat = if is_binary(reply) and reply != "", do: [%{kind: :chat, text: reply}], else: []
    chat ++ [%{kind: :page, tree: tree}]
  end

  defp drive(session_uri, caller, caps, behavior, action, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
    })
  end

  defp safe_string(s) when is_binary(s), do: s
  defp safe_string(o), do: inspect(o)
end

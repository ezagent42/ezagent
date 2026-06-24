defmodule EzagentPluginHello.TurnDriver do
  @moduledoc """
  Drives one socialware `Behavior.Turn` to land a generated page spec into the
  session's `Behavior.Surface` — the **chokepoint**: a hello page is born ONLY
  here, via `surface.put_version` (reached through `turn.compose`).

  Flow (single builder, no worker subtasks):

      turn.open → turn.compose([%{kind: :page, tree: spec}, %{kind: :chat, text: summary}]) → turn.settle

  `compose` routes the `kind: :page` ref into `Surface.put_version(turn_id, spec)`
  and the `kind: :chat` ref into a customer-visible message; `settle` advances the
  approved pointer + commits the settlement, so `CustomerFeed.snapshot/2` then
  returns the page to the anonymous visitor.

  These are sequential `:call` dispatches, so this runs in a caller process that
  can block (the builder behavior spawns it from an `{:effect, …}`), NOT inside a
  Behavior handler.

  ## Authority (Phase 0)

  Dispatches under `User.admin_uri()` + `Capability.admin_genesis_cap()` — the
  same system authority the substrate's own settlement-recovery path
  (`Behavior.Turn.recovery_effects/3`) and the socialware Turn integration test
  use to drive a session's Turn. A tighter **within-session orchestrator
  delegation** (the builder agent presenting a real `{:within_session, S}`
  delegated cap) is a Phase-0 follow-up — see the hello migration handoff.
  """

  require Logger

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Entity.User

  @doc """
  Land `spec` (a validated `EzagentPluginHello.Spec` tree) as a new approved
  Surface version on `session_uri`, with an optional customer-visible `summary`
  chat line. Returns `{:ok, turn_id}` | `{:error, reason}`.
  """
  @spec drive(URI.t(), map(), String.t(), URI.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def drive(session_uri, spec, summary \\ "", actor \\ nil)

  def drive(%URI{} = session_uri, spec, summary, actor) when is_map(spec) do
    caller = actor || User.admin_uri()

    with {:ok, %{turn_id: turn_id}} <-
           dispatch(session_uri, :turn, :open, %{
             trigger: %{source: "hello-builder"},
             opened_at: System.system_time(:millisecond)
           }, caller),
         {:ok, _composed} <-
           dispatch(session_uri, :turn, :compose, %{
             turn_id: turn_id,
             result_refs: result_refs(spec, summary)
           }, caller),
         {:ok, %{status: :settled}} <-
           dispatch(session_uri, :turn, :settle, %{turn_id: turn_id}, caller) do
      {:ok, turn_id}
    else
      {:error, reason} = err ->
        Logger.warning(
          "hello.TurnDriver: drive failed on #{URI.to_string(session_uri)}: #{inspect(reason)}"
        )

        err

      other ->
        {:error, {:unexpected, other}}
    end
  end

  defp result_refs(spec, summary) do
    chat =
      if is_binary(summary) and summary != "",
        do: [%{kind: :chat, text: summary}],
        else: []

    chat ++ [%{kind: :page, tree: spec}]
  end

  defp dispatch(session_uri, behavior, action, args, caller) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}"),
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  @doc """
  Post a builder-authored chat line into the session (ack / progress / result
  narration). `:cast` fire-and-forget; `sender = actor` so it renders as the
  builder's reply, NOT the operator's own message. Authority is the same
  admin-genesis the turn dispatches use — only the message `sender` carries the
  builder identity. No-ops on blank text.
  """
  @spec say(URI.t(), URI.t(), String.t()) :: :ok | {:ok, term()} | {:error, term()}
  def say(%URI{} = session_uri, %URI{} = actor, text) when is_binary(text) and text != "" do
    msg = Ezagent.Message.new(actor, %{text: text, attachments: []})

    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(session_uri, :session, :send),
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: actor,
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: :ignore
      }
    })
  end

  def say(_session_uri, _actor, _text), do: :ok

  @doc """
  Store the (already-sanitised) HTML site-frame for the customer page, via the
  Surface `:set_shell` action. The hybrid architecture: this hand-off frame wraps
  the json-render body at the `data-slot`. Same admin-genesis authority as the
  turn dispatches. No-ops on blank html.
  """
  @spec set_shell(URI.t(), URI.t(), String.t()) :: {:ok, term()} | {:error, term()} | :ok
  def set_shell(%URI{} = session_uri, %URI{} = actor, html) when is_binary(html) and html != "" do
    dispatch(session_uri, :surface, :set_shell, %{html: html}, actor)
  end

  def set_shell(_session_uri, _actor, _html), do: :ok
end

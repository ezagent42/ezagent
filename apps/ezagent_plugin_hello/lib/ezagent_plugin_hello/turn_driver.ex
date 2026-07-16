defmodule EzagentPluginHello.TurnDriver do
  @moduledoc """
  Drives one socialware `Behavior.Turn` to land a generated page spec into the
  session's `Behavior.Surface` — the **chokepoint**: a hello page is born ONLY
  here, via `surface.put_version` (reached through `turn.compose`).

  Flow (single builder, no worker subtasks):

      turn.open → turn.compose([%{kind: :page, tree: spec}, %{kind: :chat, text: summary}]) → turn.settle

  `compose` routes the `kind: :page` ref into `Surface.put_version(turn_id, spec)`
  and the `kind: :chat` ref into a customer-visible message; `settle` advances the
  approved pointer + commits the settlement, so `ExternalFeed.snapshot/2` then
  returns the page to the anonymous visitor.

  These are sequential `:call` dispatches, so this runs in a caller process that
  can block (the builder behavior spawns it from an `{:effect, …}`), NOT inside a
  Behavior handler.

  ## Authority (Phase 0)

  Dispatches under the chosen actor with a target-signed capability minted via
  the target Kind's `K.grant` path. No ambient admin wildcard is accepted.
  """

  require Logger

  alias Ezagent.Invocation
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
           dispatch(
             session_uri,
             :turn,
             :open,
             %{
               trigger: %{source: "hello-builder"},
               opened_at: System.system_time(:millisecond)
             },
             caller
           ),
         {:ok, _composed} <-
           dispatch(
             session_uri,
             :turn,
             :compose,
             %{
               turn_id: turn_id,
               result_refs: result_refs(spec, summary)
             },
             caller
           ),
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
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
    admin = Ezagent.Entity.User.admin_uri()

    with {:ok, signed_cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, caller, target) do
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: args,
        ctx: %{
          caller: caller,
          caps: MapSet.new([signed_cap]),
          reply: {:caller_inbox, self()}
        },
        origin: :trusted_internal
      })
    end
  end

  @doc """
  Post a builder-authored chat line into the session (ack / progress / result
  narration). `:cast` fire-and-forget; `sender = actor` so it renders as the
  builder's reply, NOT the operator's own message. Authority is the same
  admin-genesis the turn dispatches use — only the message `sender` carries the
  builder identity. No-ops on blank text.
  """
  @spec say(URI.t(), URI.t(), String.t()) :: :ok | {:ok, term()} | {:error, term()}
  def say(session_uri, actor, text), do: say_nav(session_uri, actor, text, nil)

  @doc """
  Like `say/3`, but the message body ALSO carries an optional `nav` action map
  (`%{"type" => "switch_tab" | "scroll_to" | "open_url", "value" => ...}`) that
  the viewer executes locally — the concierge's navigation-first replies (switch a
  tab / scroll / open a link). No-ops on blank text; `nil` nav == a plain `say`.
  """
  @spec say_nav(URI.t(), URI.t(), String.t(), map() | nil) ::
          :ok | {:ok, term()} | {:error, term()}
  def say_nav(%URI{} = session_uri, %URI{} = actor, text, nav)
      when is_binary(text) and text != "" do
    body = %{text: text, attachments: []}
    body = if is_map(nav), do: Map.put(body, "nav", nav), else: body
    msg = Ezagent.Message.new(actor, body)

    target = Ezagent.URI.with_action(session_uri, :session, :send)
    admin = Ezagent.Entity.User.admin_uri()

    with {:ok, signed_cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, actor, target) do
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: actor,
          caps: MapSet.new([signed_cap]),
          reply: :ignore
        },
        origin: :trusted_internal
      })
    end
  end

  def say_nav(_session_uri, _actor, _text, _nav), do: :ok

  @doc """
  Store the (already-sanitised) HTML site-frame for the customer page, via the
  Surface `:set_shell` action. The hybrid architecture: this hand-off frame wraps
  the json-render body at the `data-slot`. Same admin-genesis authority as the
  turn dispatches. No-ops on blank html.
  """
  @spec set_shell(URI.t(), URI.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, term()} | :ok
  def set_shell(session_uri, actor, html, css \\ "")

  def set_shell(%URI{} = session_uri, %URI{} = actor, html, css)
      when is_binary(html) and is_binary(css) and (html != "" or css != "") do
    dispatch(session_uri, :surface, :set_shell, %{html: html, css: to_string(css)}, actor)
  end

  def set_shell(_session_uri, _actor, _html, _css), do: :ok
end

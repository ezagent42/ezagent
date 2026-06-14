defmodule Ezagent.Behavior.CsOrchestrator do
  @moduledoc """
  Customer-service orchestration Behavior on SocialwareSession Kind.

  Ported from PR #731 (commit 23b9974, Live E2E verified), adapted:
  Kind → Behavior on SocialwareSession (not standalone Kind).
  TurnDriver calls Turn handlers directly (same-process, v3 §6.6.1).

  ## Actions
  - `:process_message` — customer message inlet (renamed from :receive
    to avoid colliding with Chat.receive on same Kind)
  - `:operator_claim` — human takeover (cancel → open → compose → claim)
  - `:operator_settle` — human submit (settle → customer_visible)

  Note: :send was removed — agent replies are delivered as chat.send by
  the bridge (framework constraint #2 from PR #740). The CsOrchestrator
  cannot intercept agent replies on this Kind; Chat handles them natively.
  """

  use Ezagent.Lifecycle, state_slice: :cs_orchestrator

  require Logger

  alias Ezagent.{Cmd, Message}
  alias EzagentPluginAutoservice.TurnDriver

  # -- TurnDriver returns 3-tuples {:ok, result, effects} per v3 §6.6.1.
  #    effects from Turn handlers must be merged into CsOrchestrator's
  #    own effect list so the Lifecycle framework processes them atomically.

  # -----------------------------------------------------------------------
  # Action declarations
  # -----------------------------------------------------------------------

  action(:process_message,
    args: %{message: :map},
    returns: %{ok: :boolean},
    caps: [:process_message],
    modes: [:cast, :call],
    description: "Customer message inlet: Turn.open + fan-out to agents"
  )

  action(:operator_claim,
    args: %{operator_uri: :uri, operator_text: :string},
    returns: %{ok: :boolean, turn_id: :string},
    caps: [:operator_claim],
    modes: [:call],
    description: "Operator takeover: cancel bot turn → open fresh → compose → claim"
  )

  action(:operator_settle,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:operator_settle],
    modes: [:call],
    description: "Operator done: Turn.settle + resume fan-out"
  )

  # -----------------------------------------------------------------------
  # Lifecycle hooks
  # -----------------------------------------------------------------------

  @impl Ezagent.Lifecycle
  def create(_args) do
    {:ok, %{open_turn_id: nil, operator_active: false}}
  end

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  @impl Ezagent.Lifecycle
  def activated(_state, _ctx), do: :ok

  # -- Allow ctx.read.(:turns, ...) for TurnDriver's direct Turn handler calls
  def reads_siblings, do: [:turns]

  # -----------------------------------------------------------------------
  # handle_process_message/2
  # -----------------------------------------------------------------------

  def handle_process_message(%{message: raw_msg}, ctx) do
    msg = normalize_message(raw_msg)
    sender_str = msg.sender |> URI.to_string()
    session_uri = ctx.self_uri

    open_turn_id = ctx.read.(:open_turn_id, nil)
    operator_active = ctx.read.(:operator_active, false)

    cond do
      sender_str == "" ->
        {:ok, %{ok: true}, []}

      is_customer_sender?(msg.sender) ->
        handle_customer_message(msg, session_uri, operator_active, ctx)

      is_agent_sender?(msg.sender) ->
        handle_agent_reply(msg, session_uri, open_turn_id, ctx)

      true ->
        {:ok, %{ok: true}, []}
    end
  end

  # -----------------------------------------------------------------------
  # handle_operator_claim/2
  # -----------------------------------------------------------------------

  def handle_operator_claim(%{operator_uri: op_uri, operator_text: operator_text}, ctx) do
    session_uri = ctx.self_uri
    open_turn_id = ctx.read.(:open_turn_id, nil)
    tctx = turn_ctx(ctx)

    # 1. Cancel in-flight bot turn (if any)
    {cancel_ok, cancel_effects} =
      if is_binary(open_turn_id) and open_turn_id != "" do
        case TurnDriver.cancel(session_uri, open_turn_id, tctx) do
          {:ok, _, te} -> {:ok, te}
          {:error, reason} ->
            Logger.error(
              "CsOrchestrator operator_claim: failed to cancel in-flight turn " <>
                "#{open_turn_id}: #{inspect(reason)}"
            )
            {{:error, {:cancel_failed, reason}}, []}
        end
      else
        {:ok, []}
      end

    case cancel_ok do
      {:error, _} = err ->
        {:ok, %{ok: false, step: :cancel, detail: inspect(err)}, cancel_effects}

      :ok ->
        trigger = %{
          message_id: "operator-claim-#{System.unique_integer([:positive])}",
          text: operator_text
        }

        case TurnDriver.open(session_uri, trigger, tctx) do
          {:ok, %{turn_id: new_tid}, open_effects} ->
            tctx2 = apply_turn_effects(tctx, open_effects)

            with {:ok, _, compose_effects} <- TurnDriver.compose(session_uri, new_tid, operator_text, tctx2),
                 {:ok, _, claim_effects} <- TurnDriver.claim(session_uri, new_tid, op_uri, tctx2) do
              turn_effects = cancel_effects ++ open_effects ++ compose_effects ++ claim_effects

              {:ok, %{ok: true, turn_id: new_tid},
               [
                 {:set, :open_turn_id, new_tid},
                 {:set, :operator_active, true}
               ] ++ turn_effects}
            else
              {:error, reason} ->
                Logger.error(
                  "CsOrchestrator operator_claim: compose/claim failed on fresh turn " <>
                    "#{new_tid}: #{inspect(reason)}"
                )
                {:ok, %{ok: false, step: :compose_or_claim, detail: inspect(reason)},
                 cancel_effects ++ open_effects}
            end

          {:error, reason} ->
            Logger.error("CsOrchestrator operator_claim: open fresh turn failed: #{inspect(reason)}")
            {:ok, %{ok: false, step: :open, detail: inspect(reason)}, cancel_effects}
        end
    end
  end

  # -----------------------------------------------------------------------
  # handle_operator_settle/2
  # -----------------------------------------------------------------------

  def handle_operator_settle(_args, ctx) do
    session_uri = ctx.self_uri
    turn_id = ctx.read.(:open_turn_id, nil)

    if is_nil(turn_id) or turn_id == "" do
      {:ok, %{ok: false}, []}
    else
      tctx = turn_ctx(ctx)

      case TurnDriver.settle(session_uri, turn_id, tctx) do
        {:ok, _, turn_effects} ->
          {:ok, %{ok: true},
           [
             {:set, :operator_active, false},
             {:set, :open_turn_id, nil}
           ] ++ turn_effects}

        {:error, reason} ->
          Logger.error(
            "CsOrchestrator operator_settle failed: #{inspect(reason)}, turn_id=#{turn_id}"
          )
          {:ok, %{ok: false}, []}
      end
    end
  end

  # -----------------------------------------------------------------------
  # Private — customer message handler
  # -----------------------------------------------------------------------

  defp handle_customer_message(msg, session_uri, operator_active, ctx) do
    tctx = turn_ctx(ctx)
    trigger = %{message_id: msg.id, text: extract_text(msg.body)}

    {stale_effects, stale_error} = cancel_stale_turn(session_uri, ctx, tctx)

    case TurnDriver.open(session_uri, trigger, tctx) do
      {:ok, %{turn_id: tid}, open_effects} ->
        base_effects = [{:set, :open_turn_id, tid}]

        fanout_effects =
          if operator_active do
            []
          else
            build_fanout_effects(msg, ctx)
          end

        all_effects = stale_effects ++ open_effects ++ base_effects ++ fanout_effects

        if stale_error do
          Logger.warning("CsOrchestrator: failed to cancel superseded turn — proceeding")
        end

        {:ok, %{ok: true}, all_effects}

      {:error, reason} ->
        Logger.error(
          "CsOrchestrator TurnDriver.open failed: #{inspect(reason)}, msg_id=#{msg.id}"
        )
        {:ok, %{ok: false}, stale_effects}
    end
  end

  defp cancel_stale_turn(session_uri, ctx, tctx) do
    stale_tid = ctx.read.(:open_turn_id, nil)

    if stale_tid != nil and stale_tid != "" do
      case TurnDriver.cancel(session_uri, stale_tid, tctx) do
        {:ok, _, te} -> {te, false}
        {:error, reason} ->
          Logger.warning(
            "CsOrchestrator: failed to cancel superseded turn #{stale_tid}: #{inspect(reason)} — proceeding"
          )
          {[], true}
      end
    else
      {[], false}
    end
  end

  # -----------------------------------------------------------------------
  # Private — agent reply handler (dead code until framework constraint #2
  #           is resolved; kept for future framework upgrade path)
  # -----------------------------------------------------------------------

  defp handle_agent_reply(msg, session_uri, open_turn_id, ctx) do
    tctx = turn_ctx(ctx)
    text = extract_text(msg.body)

    {tid, heal_effects} =
      if is_nil(open_turn_id) or open_turn_id == "" do
        trigger = %{message_id: "self-heal-#{System.unique_integer([:positive])}", text: text}
        case TurnDriver.open(session_uri, trigger, tctx) do
          {:ok, %{turn_id: id}, oe} -> {id, oe}
          {:error, reason} ->
            Logger.error("CsOrchestrator agent reply self-heal open failed: #{inspect(reason)}")
            {nil, []}
        end
      else
        {open_turn_id, []}
      end

    if is_nil(tid) do
      {:ok, %{ok: false}, heal_effects}
    else
      with {:ok, _, compose_effects} <- TurnDriver.compose(session_uri, tid, text, tctx),
           {:ok, _, settle_effects} <- TurnDriver.settle(session_uri, tid, tctx) do
        {:ok, %{ok: true},
         heal_effects ++ compose_effects ++ settle_effects ++ [{:set, :open_turn_id, nil}]}
      else
        {:error, reason} ->
          Logger.error(
            "CsOrchestrator agent reply compose/settle failed: #{inspect(reason)}, turn_id=#{tid}"
          )
          {:ok, %{ok: false}, heal_effects}
      end
    end
  end

  # -----------------------------------------------------------------------
  # Private — fan-out effects (P22: dispatch_after_commit)
  # -----------------------------------------------------------------------

  defp build_fanout_effects(msg, ctx) do
    self_uri = ctx.self_uri

    reply_caps =
      "chat-reply"
      |> Ezagent.SystemPrincipal.uri()
      |> Ezagent.SystemPrincipal.caps()

    [
      {:dispatch_after_commit,
       Cmd.new(self_uri, :send, %{message: msg}, %{
         caller: self_uri,
         caps: reply_caps,
         reply: :ignore
       })}
    ]
  end

  # -----------------------------------------------------------------------
  # Private — sender classification
  # -----------------------------------------------------------------------

  defp is_customer_sender?(%URI{scheme: scheme})
       when scheme in ["entity", "user"],
       do: true

  defp is_customer_sender?(_), do: false

  defp is_agent_sender?(%URI{scheme: scheme})
       when scheme in ["agent", "system"],
       do: true

  defp is_agent_sender?(_), do: false

  # -----------------------------------------------------------------------
  # Private — helpers
  # -----------------------------------------------------------------------

  # Pass the full Lifecycle ctx to TurnDriver, which forwards it to Turn handlers.
  # Turn needs ctx.self_uri (for turn_id), ctx.caller (for turn owner),
  # ctx.read (:turns slice), and ctx.caps (for authz).
  defp turn_ctx(ctx), do: ctx

  # Apply Turn effects to ctx so subsequent TurnDriver calls see updated state.
  # Needed because Turn effects from one call (e.g. open) aren't committed by
  # the Lifecycle framework until the handler returns — but the next call
  # (e.g. compose) needs the open's state change to be visible.
  defp apply_turn_effects(ctx, effects) do
    Enum.reduce(effects, ctx, fn
      {:set, key, value}, acc ->
        # Patch ctx.read to return the new value for this key
        old_read = Map.get(acc, :read, fn _, d -> d end)
        new_read = fn k, d ->
          if k == key, do: value, else: old_read.(k, d)
        end
        Map.put(acc, :read, new_read)

      _, acc ->
        acc
    end)
  end

  defp normalize_message(%Message{} = msg), do: msg

  defp normalize_message(raw) when is_map(raw) do
    msg = struct(Message, Map.new(raw, fn {k, v} -> {to_atom_key(k), v} end))

    sender =
      case msg.sender do
        %URI{} = u -> u
        s when is_binary(s) -> s
        _ -> msg.sender
      end

    %{msg | sender: sender}
  end

  defp to_atom_key(k) when is_atom(k), do: k
  defp to_atom_key(k) when is_binary(k), do: String.to_existing_atom(k)

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  # -----------------------------------------------------------------------
  # Data ownership
  # -----------------------------------------------------------------------

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end

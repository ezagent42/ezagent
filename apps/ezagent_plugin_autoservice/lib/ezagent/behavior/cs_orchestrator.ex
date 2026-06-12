defmodule Ezagent.Behavior.CsOrchestrator do
  @moduledoc """
  Customer-service orchestration Behavior on SocialwareSession Kind.

  Ported from PR #731 (commit 23b9974, Live E2E verified), adapted:
  Kind → Behavior on SocialwareSession (not standalone Kind).
  Session URI / customer URI / agent URIs come from Session context,
  not stored in orchestrator state.

  ## Actions
  - `:receive` — customer message inlet (via MentionRouting fan-out)
  - `:send` — agent-reply inlet (bridge delivers as chat.send)
  - `:operator_claim` — human takeover (cancel → open → compose → claim)
  - `:operator_settle` — human submit (settle → customer_visible)

  ## P22 compliance
  TurnDriver failures are logged but do NOT crash the handler.
  Fan-out uses `dispatch_after_commit`.
  """

  use Ezagent.Lifecycle, state_slice: :cs_orchestrator

  require Logger

  alias Ezagent.{Cmd, Message}
  alias EzagentPluginAutoservice.TurnDriver

  # -----------------------------------------------------------------------
  # Action declarations
  # -----------------------------------------------------------------------

  action(:receive,
    args: %{message: :map},
    returns: %{ok: :boolean},
    caps: [:receive],
    modes: [:cast, :call],
    description: "Customer message inlet: Turn.open + fan-out to agents"
  )

  # Agent replies arrive via the bridge as `chat.send`. Same payload shape
  # as `:receive` — delegates to handle_receive/2. Without this, slow cc
  # reply is dropped with {:unknown_action, :send} (PR #731 Live E2E bug).
  action(:send,
    args: %{message: :map},
    returns: %{ok: :boolean},
    caps: [:send],
    modes: [:cast, :call],
    description: "Agent-reply inlet: bridge dispatches fast/slow replies as chat.send"
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

  # -----------------------------------------------------------------------
  # handle_send/2 — delegates to handle_receive/2
  # -----------------------------------------------------------------------

  def handle_send(args, ctx), do: handle_receive(args, ctx)

  # -----------------------------------------------------------------------
  # handle_receive/2
  # -----------------------------------------------------------------------

  def handle_receive(%{message: raw_msg}, ctx) do
    msg = normalize_message(raw_msg)
    sender_str = msg.sender |> URI.to_string()
    session_uri = ctx.self_uri

    open_turn_id = ctx.read.(:open_turn_id, nil)
    operator_active = ctx.read.(:operator_active, false)

    cond do
      sender_str == "" ->
        {:ok, %{ok: true}, []}

      # Customer message (sender is a user URI, not an agent)
      is_customer_sender?(msg.sender) ->
        handle_customer_message(msg, session_uri, operator_active, ctx)

      # Agent reply (fast/slow agent sender)
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
    cancel_result =
      if is_binary(open_turn_id) and open_turn_id != "" do
        case TurnDriver.cancel(session_uri, open_turn_id, tctx) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "CsOrchestrator operator_claim: failed to cancel in-flight turn " <>
                "#{open_turn_id}: #{inspect(reason)}"
            )

            {:error, {:cancel_failed, reason}}
        end
      else
        :ok
      end

    case cancel_result do
      {:error, _} = err ->
        {:ok, %{ok: false, step: :cancel, detail: inspect(err)}, []}

      :ok ->
        # 2. Open a fresh turn
        trigger = %{message_id: "operator-claim-#{System.unique_integer([:positive])}", text: operator_text}

        case TurnDriver.open(session_uri, trigger, tctx) do
          {:ok, %{turn_id: new_tid}} ->
            # 3. Compose operator text + 4. Claim (visibility → operator_only)
            with {:ok, _} <- TurnDriver.compose(session_uri, new_tid, operator_text, tctx),
                 {:ok, _} <- TurnDriver.claim(session_uri, new_tid, op_uri, tctx) do
              {:ok, %{ok: true, turn_id: new_tid},
               [
                 {:set, :open_turn_id, new_tid},
                 {:set, :operator_active, true}
               ]}
            else
              {:error, reason} ->
                Logger.error(
                  "CsOrchestrator operator_claim: compose/claim failed on fresh turn " <>
                    "#{new_tid}: #{inspect(reason)}"
                )

                {:ok, %{ok: false, step: :compose_or_claim, detail: inspect(reason)}, []}
            end

          {:error, reason} ->
            Logger.error("CsOrchestrator operator_claim: open fresh turn failed: #{inspect(reason)}")
            {:ok, %{ok: false, step: :open, detail: inspect(reason)}, []}
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
        {:ok, _} ->
          {:ok, %{ok: true},
           [
             {:set, :operator_active, false},
             {:set, :open_turn_id, nil}
           ]}

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

    # Cancel stale open turn from previous interaction
    stale_tid = ctx.read.(:open_turn_id, nil)

    if stale_tid != nil and stale_tid != "" do
      case TurnDriver.cancel(session_uri, stale_tid, tctx) do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning(
            "CsOrchestrator: failed to cancel superseded turn #{stale_tid}: #{inspect(reason)} — proceeding"
          )
      end
    end

    case TurnDriver.open(session_uri, trigger, tctx) do
      {:ok, %{turn_id: tid}} ->
        base_effects = [{:set, :open_turn_id, tid}]

        effects =
          if operator_active do
            base_effects
          else
            base_effects ++ build_fanout_effects(msg, ctx)
          end

        {:ok, %{ok: true}, effects}

      {:error, reason} ->
        Logger.error(
          "CsOrchestrator TurnDriver.open failed: #{inspect(reason)}, msg_id=#{msg.id}"
        )

        {:ok, %{ok: false}, []}
    end
  end

  # -----------------------------------------------------------------------
  # Private — agent reply handler
  # -----------------------------------------------------------------------

  defp handle_agent_reply(msg, session_uri, open_turn_id, ctx) do
    tctx = turn_ctx(ctx)
    text = extract_text(msg.body)

    # Self-heal: if no open_turn_id (e.g. restart), open a degenerate turn
    tid_result =
      if is_nil(open_turn_id) or open_turn_id == "" do
        trigger = %{message_id: "self-heal-#{System.unique_integer([:positive])}", text: text}
        TurnDriver.open(session_uri, trigger, tctx)
      else
        {:ok, %{turn_id: open_turn_id}}
      end

    case tid_result do
      {:ok, %{turn_id: tid}} ->
        with {:ok, _} <- TurnDriver.compose(session_uri, tid, text, tctx),
             {:ok, _} <- TurnDriver.settle(session_uri, tid, tctx) do
          {:ok, %{ok: true}, [{:set, :open_turn_id, nil}]}
        else
          {:error, reason} ->
            Logger.error(
              "CsOrchestrator agent reply compose/settle failed: #{inspect(reason)}, turn_id=#{tid}"
            )

            {:ok, %{ok: false}, []}
        end

      {:error, reason} ->
        Logger.error("CsOrchestrator agent reply self-heal open failed: #{inspect(reason)}")
        {:ok, %{ok: false}, []}
    end
  end

  # -----------------------------------------------------------------------
  # Private — fan-out effects
  # -----------------------------------------------------------------------

  # Build {:dispatch_after_commit, Cmd} effects for fast + slow agent fan-out.
  # P22: dead agent must NOT abort turn-open commit.
  defp build_fanout_effects(msg, ctx) do
    self_uri = ctx.self_uri

    reply_caps =
      "chat-reply"
      |> Ezagent.SystemPrincipal.uri()
      |> Ezagent.SystemPrincipal.caps()

    # Fan-out to agents via chat.send on this session — MentionRouting
    # will pick the correct agent(s) based on the session's routing rules.
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

  defp turn_ctx(%{self_uri: self_uri, caps: caps}) do
    %{caller: self_uri, caps: caps}
  end

  defp turn_ctx(ctx) do
    %{
      caller: Map.get(ctx, :self_uri, :system),
      caps: Map.get(ctx, :caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))
    }
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
  # Sibling reads & data ownership
  # -----------------------------------------------------------------------

  @spec reads_siblings() :: []
  def reads_siblings, do: []

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end

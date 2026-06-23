defmodule EzagentPluginEcho.BridgeAdapter do
  @moduledoc """
  Echo flavor AgentBridge adapter — the `:in_process_sync` TRANSPORT.

  ## Why this exists (A8 — echo-on-receive regression fix)

  After the A1-A5 echo→`Entity.Agent` refactor, `{Entity.Agent, :receive}`
  is globally registered to `Behavior.Agent.Receive`, which delegates to
  `AgentBridge` based on flavor. Without a registered echo adapter the
  delivery fell to the `:subprocess_ws` default — no channel, no bridge,
  silent drop. `Behavior.Echo.handle_receive/2` was NEVER called.

  This adapter plugs the gap using the same `:in_process_sync` pattern as
  `EzagentPluginCurlAgent.BridgeAdapter` (PR-6). Echo is far simpler than
  curl: it has NO subprocess, NO API call, and NO durable conversation
  state to read. `deliver/2` reconstructs a `%Ezagent.Message{}` from the
  payload, calls `Behavior.Echo.handle_receive/2` directly (the function,
  not a dispatch — we are already inside the agent's Kind process), and
  fire-and-forget-dispatches the resulting `{:dispatch, cmd}` effects (the
  "echo: <text>" `session.send` reply). State-mutation effects (`{:set,
  …}`) are returned as the sync result so `Behavior.Echo.handle_sync_result/2`
  can commit them in the follow-up `:sync_result` re-dispatch that
  `Behavior.Agent.Receive` enqueues automatically for all `:in_process_sync`
  adapters.

  ## Transport class — `:in_process_sync`

  `Ezagent.AgentBridge.deliver` routes the `:in_process_sync` class straight
  here (no Channel lookup, no subprocess readiness gate). `deliver/2` runs
  INSIDE the agent Kind's dispatch process (the `agent.receive` handler calls
  `Delivery.deliver_agent_receive` synchronously). Reading the agent's OWN
  live slice via `Kind.get_slice/2` here would deadlock — we do NOT do that.
  Echo needs no snapshot read: the reply text is purely derived from the
  inbound message.

  ## Return shape

  `deliver/2 :: {:ok, []}`. Echo has no post-adapter state to persist: the
  slice state-mutation effects (`{:set, :count, _}` / `{:set, :last_msg, _}`)
  are discarded here because `{Entity.Agent, :sync_result}` is already globally
  bound to `Behavior.CurlAgent` — registering it again for echo would crash at
  boot (same capability-conflict gate as `:receive`). The deferred `:sync_result`
  `:cast` that `Behavior.Agent.Receive` enqueues for all `:in_process_sync`
  adapters will fail with `{:behavior_not_in_instance_set}` for echo agents (a
  best-effort silent drop — it is a `:cast`). Echo's echo reply is already fired
  synchronously in `deliver/2` before the re-dispatch is even enqueued, so the
  drop is harmless. The `:count` / `:last_msg` slice fields are therefore NOT
  updated on `:receive` via `AgentBridge` (they ARE updated on `:say`). This is a
  known limitation documented in the A8 report; a per-flavor `:sync_result`
  binding redesign (option C from A7) would resolve it.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  require Logger

  alias Ezagent.AgentBridge.Payload
  alias Ezagent.{Behavior, Invocation, Message}

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "echo"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: :in_process_sync

  @impl Ezagent.AgentBridge.Adapter
  def deliver(%Payload{} = payload, nil) do
    with {:ok, agent_uri} <- agent_uri_from_payload(payload),
         {:ok, msg} <- message_from_payload(payload) do
      # Build a minimal ctx for Behavior.Echo.handle_receive/2. The function
      # needs :self_uri (to build the sender on the reply Message) and :caller
      # (session URI, so handle_receive can address the session.send target).
      #
      # ctx[:read] is the lifecycle reader thunk — echo's handle_receive reads
      # :count from it. We supply a minimal reader that always returns the
      # default (0 for :count) since we are not inside the slice commit cycle
      # here. The `:set` effects returned by handle_receive are bundled into
      # the sync result and committed in the follow-up :sync_result dispatch.
      # ctx.caller must be the SESSION URI (so handle_receive can build the
      # session.send target). Delivery puts the session URI in payload.session_uri
      # and also in payload.meta["session"]; sender_uri is the USER who sent
      # the message (used as msg.sender, not as the session address).
      session_uri =
        case payload.session_uri do
          %URI{} = u ->
            u

          _ ->
            case get_in(payload.meta, ["session"]) do
              s when is_binary(s) and s != "" ->
                try do
                  Ezagent.URI.new!(s)
                rescue
                  ArgumentError -> nil
                end

              _ ->
                nil
            end
        end

      ctx = %{
        self_uri: agent_uri,
        caller: session_uri,
        read: fn key, default -> Map.get(%{count: 0, last_msg: nil}, key, default) end
      }

      # Behavior.Echo.handle_receive/2 always returns {:ok, _, effects} —
      # match directly (the compiler knows the return type is non-error).
      {:ok, _result, effects} = Behavior.Echo.handle_receive(%{message: msg}, ctx)

      # Fire {:dispatch, cmd} effects immediately in-process — the session.send
      # echo reply must reach the session synchronously within this deliver/2 call.
      # {:set, k, v} effects are discarded: {Entity.Agent, :sync_result} is
      # globally bound to Behavior.CurlAgent; echo cannot register it without a
      # boot crash. The deferred :sync_result :cast from Agent.Receive will fail
      # with {:behavior_not_in_instance_set} for echo (best-effort silent drop).
      Enum.each(effects, fn
        {:dispatch, cmd} ->
          _ =
            Invocation.dispatch(%Invocation{
              target: cmd.target,
              mode: :cast,
              args: cmd.args,
              ctx: cmd.ctx
            })

        _ ->
          :ok
      end)

      # Return empty — no sync state to persist (echo is stateless from the
      # bridge's perspective; the :sync_result re-dispatch is a harmless drop).
      {:ok, %{}}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp agent_uri_from_payload(%Payload{meta: meta}) when is_map(meta) do
    case Map.get(meta, "agent_uri") do
      uri_str when is_binary(uri_str) and uri_str != "" ->
        {:ok, Ezagent.URI.new!(uri_str)}

      _ ->
        {:error, :no_agent_uri_in_payload}
    end
  rescue
    ArgumentError -> {:error, :malformed_agent_uri}
  end

  defp agent_uri_from_payload(_), do: {:error, :no_agent_uri_in_payload}

  # Reconstruct a minimal %Message{} from the delivery payload so
  # Behavior.Echo.handle_receive/2 gets the shape it expects.
  # The message body carries the inbound text; sender and session are
  # extracted from the payload fields Delivery set when building it.
  defp message_from_payload(%Payload{} = payload) do
    sender_uri =
      case payload.sender_uri do
        %URI{} = u -> u
        _ -> nil
      end

    if is_nil(sender_uri) do
      {:error, :no_sender_in_payload}
    else
      msg = Message.new(sender_uri, %{text: payload.text || "", attachments: []})
      {:ok, msg}
    end
  end
end

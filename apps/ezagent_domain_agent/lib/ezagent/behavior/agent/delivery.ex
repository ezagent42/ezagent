defmodule Ezagent.ActionSet.Agent.Delivery do
  @moduledoc false

  # Agent-domain delivery seam. Owns the agent-branch `:receive` delivery that
  # `Ezagent.ActionSet.Agent.Receive` drives. Relocated (PR-A, #53) out of the
  # session-side delivery helper so the agent domain no longer compile-depends
  # on any session Behavior — the prerequisite for the `im → session → agent`
  # acyclic domain split. Builds a flavor-neutral
  # `Ezagent.AgentBridge.Payload` and delivers via `Ezagent.AgentBridge`,
  # resolving the agent's transport class (`:subprocess_ws` / `:in_process_sync`).
  # Pure message-body accessors are shared via `Ezagent.Message.Body` (core).

  alias Ezagent.Message
  alias Ezagent.Message.Body

  @doc """
  Agent-branch `:receive` delivery. Builds a flavor-neutral
  `Ezagent.AgentBridge.Payload` from the message + ctx and delivers it via
  `Ezagent.AgentBridge`, self-healing a vanished bridge. Runs in the same
  Agent Kind process as the handler.

  Returns a CLASS-TAGGED result so the caller stays flavor-blind:

    * `:subprocess_ws` flavors (cc / codex) → `:ok` REGARDLESS of the
      delivery outcome (the agent's reply is ASYNC, back through the bridge
      → `session.send`; a missing bridge is best-effort, already logged by
      AgentBridge). The caller emits no further effects.
    * `:in_process_sync` flavors (curl, PR-6) → `{:sync, result}` where
      `result` is the adapter's `{:ok, _}` / `{:error, _}` round-trip
      outcome. The caller (`Agent.Receive`) re-dispatches that result into
      the flavor's `:sync_result` Behavior so the Behavior persists it (the
      adapter is transport-only). The `{:sync, _}` tag — NOT the raw return
      shape — is what distinguishes the two classes, so a `:subprocess_ws`
      `{:error, :no_bridge}` is never mistaken for a sync result.
  """
  @spec deliver_agent_receive(Message.t(), map()) ::
          :ok | {:sync, String.t(), {:ok, term()} | {:error, term()}}
  def deliver_agent_receive(%Message{} = msg, ctx) do
    # AgentBridge PR-D: keep chat receive flavor-neutral. The
    # bridge domain resolves the bound channel and adapter for the
    # agent URI; missing bridge/adapter remains best-effort for
    # this cast receive path but is logged by AgentBridge.deliver/2.
    source_session =
      case Map.get(ctx, :caller) do
        %URI{} = u -> URI.to_string(u)
        s when is_binary(s) -> s
        _ -> ""
      end

    attachments = Body.body_attachments(msg.body)
    attachment_hint = Body.attachment_hint_text(attachments)

    text_with_hint =
      case {Body.body_text(msg.body), attachment_hint} do
        {"", ""} -> ""
        {t, ""} -> t
        {"", hint} -> hint
        {t, hint} -> t <> "\n" <> hint
      end

    base_meta = %{
      "sender" => Ezagent.URI.stable_key(msg.sender),
      "message_id" => msg.id,
      "session" => source_session,
      # PR-6 — the recipient agent's OWN URI, so an `:in_process_sync`
      # adapter (curl) can read the agent's persisted slices from the
      # snapshot store to assemble its request (deadlock-safe; the adapter
      # runs inside the agent Kind's dispatch process so a live
      # `Kind.get_slice` self-call would deadlock).
      "agent_uri" => agent_uri_meta(ctx)
    }

    # Invariant #3 (channel notification `meta` is `Record<string, string>`):
    # `ref_id` is `nil` for every non-reply message (the common case), so it
    # can only be added when it is actually a non-empty string — an
    # unconditional `msg.ref_id` here silently drops the WHOLE notification
    # on the claude TUI side (PR 26).
    base_meta =
      case msg.ref_id do
        ref_id when is_binary(ref_id) and ref_id != "" -> Map.put(base_meta, "ref_id", ref_id)
        _ -> base_meta
      end

    meta =
      case Body.first_attachment_path(attachments) do
        nil -> base_meta
        path -> Map.put(base_meta, "file_path", path)
      end

    session_uri =
      case msg.session_uri do
        %URI{} = uri -> uri
        s when is_binary(s) and s != "" -> Ezagent.URI.new!(s)
        _ when source_session != "" -> Ezagent.URI.new!(source_session)
        _ -> nil
      end

    payload = %Ezagent.AgentBridge.Payload{
      message_id: msg.id,
      session_uri: session_uri,
      sender_uri: msg.sender,
      text: text_with_hint,
      event_type: :chat_send,
      attachments: attachments,
      meta: meta
    }

    # PR-DR (blocker #1): self-heal a vanished bridge before dropping. If
    # the agent's claude/python subprocess exited (its WS Channel.terminate
    # unbound the Registry row), `deliver_ensuring/2` relaunches it
    # (snapshot-sourced, flavor-neutral) + awaits the rebind, then retries
    # once — instead of silently `:no_bridge`-dropping the routed message.
    #
    # PR-6 — the delivery is dispatched per the agent's transport class and
    # the result is CLASS-TAGGED. `:subprocess_ws` → `:ok` (async reply, even
    # on a best-effort drop); `:in_process_sync` → `{:sync, result}` the
    # caller re-dispatches into the flavor's `:sync_result` Behavior.
    #
    # Flavor resolution: prefer the in-process ctx-sandbox flavor (no
    # `Kind.get_slice` self-call), but FALL BACK to the durable flavor query
    # `AgentBridge.deliver` itself uses (`AgentFlavorAttributes` → sandbox).
    # The curl flavor lives in `AgentFlavorAttributes` (O-2, a stored slice
    # field), NOT the sandbox template_class, so the ctx-sandbox path returns
    # `:none` for curl — without this fallback the in-process-sync result
    # would be silently discarded down the `:subprocess_ws` async branch.
    flavor = resolve_delivery_flavor(ctx)

    if in_process_sync?(flavor) do
      {:ok, fl} = flavor
      {:sync, fl, Ezagent.AgentBridge.deliver_ensuring_with_flavor(ctx[:self_uri], payload, fl)}
    else
      _ =
        case flavor do
          {:ok, fl} ->
            Ezagent.AgentBridge.deliver_ensuring_with_flavor(ctx[:self_uri], payload, fl)

          :none ->
            Ezagent.AgentBridge.deliver_ensuring(ctx[:self_uri], payload)
        end

      :ok
    end
  end

  # Resolve the delivery flavor: ctx-sandbox first (deadlock-safe in-process
  # read), then the ETS launch-attribute fast-path, then the DURABLE snapshot
  # slice (codex P1) so the transport-class decision survives a cold-load.
  defp resolve_delivery_flavor(ctx) do
    case resolve_agent_flavor_from_ctx(ctx) do
      {:ok, _} = ok ->
        ok

      :none ->
        case Map.get(ctx, :self_uri) do
          %URI{} = uri -> resolve_delivery_flavor_for(uri)
          _ -> :none
        end
    end
  end

  # codex P1 (PR-6) — the curl flavor is a DURABLE slice field (O-2: stored
  # state), so it MUST survive a BEAM restart / lazy demand-spawn from
  # `kind_snapshots`. The ETS `AgentFlavorAttributes` row is an OPTIONAL
  # fast-path — gone after a cold restart — so it can NEVER be the sole
  # source: when it misses, fall back to the persisted slice in the snapshot
  # store. Without this, a rehydrated curl agent resolves `:none` → its
  # `:in_process_sync` receive is mis-routed down the `:subprocess_ws` async
  # branch and silently DROPPED (no live channel).
  #
  # Both reads are deadlock-safe inside the agent's OWN dispatch process: ETS
  # is a plain table read, and `SnapshotStore.latest/1` is a DB read — neither
  # is a `Kind.get_slice(self_uri)` self-`call`.
  defp resolve_delivery_flavor_for(%URI{} = uri) do
    case Ezagent.AgentFlavorAttributes.get(uri) do
      {:ok, flavor} when is_binary(flavor) and flavor != "" ->
        {:ok, flavor}

      _ ->
        # Durable snapshot fallback — the SHARED, deadlock-safe scan also used by
        # the canonical `UriQuery.resolve(:flavor, _)` resolver (codex P2).
        # Delivery runs inside the agent's OWN dispatch process, so it can only
        # use this ETS + `SnapshotStore` path (NOT the resolver's sandbox
        # `Kind.get_slice/2` branch, which would self-`call` and deadlock); both
        # share one snapshot-scan impl so a cold-loaded curl agent resolves
        # identically here and for every external caller.
        Ezagent.AgentFlavorResolver.flavor_from_durable_snapshot(uri)
    end
  end

  # The transport class is `:in_process_sync` ONLY when the agent's flavor
  # resolved AND its registered adapter declares that class. A `:none` flavor
  # or a `:subprocess_ws` adapter (or no adapter yet) is NOT sync.
  defp in_process_sync?({:ok, flavor}) when is_binary(flavor) do
    Ezagent.AgentBridge.AdapterRegistry.transport_class(flavor) == :in_process_sync
  end

  defp in_process_sync?(_), do: false

  defp agent_uri_meta(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp resolve_agent_flavor_from_ctx(ctx) do
    ctx
    |> get_in([:siblings, :sandbox])
    |> Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox()
  end
end

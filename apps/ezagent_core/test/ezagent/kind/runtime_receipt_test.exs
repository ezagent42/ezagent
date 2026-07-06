defmodule Ezagent.Kind.RuntimeReceiptTest do
  @moduledoc """
  Reputation Receipt (facts layer, minimal) — the exhaust of the Cap-BAC
  authorization flow. `Ezagent.Kind.Runtime.handle_dispatch/4` emits exactly
  one durable `:receipt` EventLog row on the SUCCESS path of an authorized
  invocation that actually crossed a workspace ("cross-org") boundary.

  Gates (per memory `feedback_completion_requires_invariant_test`):

  1. A cross-workspace authorized dispatch emits exactly one `:receipt` row
     carrying the right caller / provider / capability identity_key / action /
     `outcome = :fulfilled`, with `signature == nil` + `provenance_ref == nil`.
  2. An intra-workspace (same-workspace) authorized dispatch emits NO receipt.
  3. A denied dispatch (the matched-cap threading is behavior-preserving —
     same allow/deny decision) emits no receipt.
  4. A receipt-write failure never propagates — it is swallowed, so it can
     never break or slow the dispatch reply.

  The fixtures are inline (a minimal cap-gated Behavior + Kind) so the dispatch
  reaches the success branch reliably without racing a real Session/Chat DB
  insert.
  """

  # DataCase shares the Ecto sandbox module-wide via a drainable Agent owner,
  # so the EventLog receipt write runs under a safe shared connection.
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — resolves only in the umbrella.
  @moduletag :umbrella_only

  alias Ezagent.{BehaviorRegistry, Capability, EventLog, Invocation}

  # --- Fixtures -------------------------------------------------------------

  # Minimal new-contract Behavior with a single cap-gated action that always
  # succeeds (so the dispatch reaches the Receipt-emitting success branch).
  defmodule ReceiptFixtureBehavior do
    @moduledoc false
    use Ezagent.ActionSet

    action(:ping,
      args: %{},
      returns: %{ok: :boolean},
      caps: [:ping],
      modes: [:call]
    )

    def state_slice, do: :receipt_fixture

    def handle_ping(_args, _ctx) do
      {:ok, %{ok: true}, [{:set, :pinged, true}]}
    end
  end

  defmodule ReceiptFixtureKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :receipt_fixture

    @impl true
    def behaviors, do: [ReceiptFixtureBehavior]

    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = BehaviorRegistry.register(ReceiptFixtureKind, :ping, ReceiptFixtureBehavior)

    suffix = System.unique_integer([:positive])

    # Provider (target) lives in workspace A; caller lives in workspace B.
    # Entity URIs derive their workspace structurally (1st authority segment)
    # — no WorkspaceRegistry.bind needed, unlike session:// URIs.
    provider_uri = URI.new!("entity://receipt-prov-#{suffix}/agent/provider")
    caller_uri = URI.new!("entity://receipt-call-#{suffix}/user/caller")
    same_ws_caller_uri = URI.new!("entity://receipt-prov-#{suffix}/user/insider")

    {:ok,
     provider_uri: provider_uri, caller_uri: caller_uri, same_ws_caller_uri: same_ws_caller_uri}
  end

  # A ctx.caps cross-workspace cap (`workspace_uri: :any`) that both authorizes
  # `:ping` at step 5.5 AND provides the step-5.6 cross-workspace bypass.
  # `granted_by` is a real entity URI so it clears #154 predicate A.
  defp cross_workspace_cap(granted_by_uri) do
    %Capability{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: granted_by_uri,
      granted_at: ~U[2026-07-01 00:00:00Z]
    }
  end

  # A same-workspace cap — concrete `workspace_uri`, so it authorizes `:ping`
  # inside its own workspace but is NOT a cross-workspace marker.
  defp intra_workspace_cap(workspace_uri, granted_by_uri) do
    %Capability{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: :any,
      workspace_uri: workspace_uri,
      granted_by: granted_by_uri,
      granted_at: ~U[2026-07-01 00:00:00Z]
    }
  end

  defp ping_invocation(provider_uri, caller_uri, caps) do
    target = URI.parse("#{URI.to_string(provider_uri)}?action=receipt_fixture.ping")

    %Invocation{
      target: target,
      mode: :call,
      args: %{},
      ctx: %{caller: caller_uri, caps: caps, reply: :ignore}
    }
  end

  defp receipt_rows(provider_uri) do
    provider_uri
    |> EventLog.stream_by_aggregate()
    |> Enum.filter(&(&1.event_name == "receipt"))
  end

  # --- Tests ----------------------------------------------------------------

  test "cross-workspace authorized dispatch emits exactly one :receipt fact", %{
    provider_uri: provider_uri,
    caller_uri: caller_uri
  } do
    cap = cross_workspace_cap(caller_uri)
    inv = ping_invocation(provider_uri, caller_uri, MapSet.new([cap]))

    state = %{receipt_fixture: %{}}

    assert {:ok, _new_state, result, _evt, _deferred} =
             Ezagent.Kind.Runtime.handle_dispatch(inv, state, ReceiptFixtureKind, provider_uri)

    assert result == %{ok: true}

    rows = receipt_rows(provider_uri)
    assert length(rows) == 1, "expected exactly one :receipt row, got #{length(rows)}"

    [row] = rows
    # Aggregate (EventLog `target`) is the provider instance.
    assert row.aggregate_uri == URI.to_string(provider_uri)

    payload = row.payload
    assert payload["caller"] == URI.to_string(caller_uri)
    assert payload["provider"] == URI.to_string(provider_uri)
    assert payload["action"] == "ping"
    assert payload["outcome"] == "fulfilled"
    # Reserved-but-empty from day one.
    assert payload["signature"] == nil
    assert payload["provenance_ref"] == nil

    # capability = the matched cap's identity_key, flattened to a JSON-safe map.
    assert payload["capability"] == %{
             "kind" => "any",
             "behavior" => "any",
             "action" => "any",
             "instance" => "any",
             "workspace_uri" => "any"
           }
  end

  test "intra-workspace authorized dispatch emits NO receipt", %{
    provider_uri: provider_uri,
    same_ws_caller_uri: same_ws_caller_uri
  } do
    provider_ws = Capability.workspace_of(provider_uri)
    cap = intra_workspace_cap(provider_ws, same_ws_caller_uri)
    inv = ping_invocation(provider_uri, same_ws_caller_uri, MapSet.new([cap]))

    state = %{receipt_fixture: %{}}

    assert {:ok, _new_state, result, _evt, _deferred} =
             Ezagent.Kind.Runtime.handle_dispatch(inv, state, ReceiptFixtureKind, provider_uri)

    assert result == %{ok: true}

    assert receipt_rows(provider_uri) == [],
           "intra-workspace dispatch must not emit a reputation receipt"
  end

  test "denied dispatch emits no receipt (matched-cap threading is behavior-preserving)", %{
    provider_uri: provider_uri,
    caller_uri: caller_uri
  } do
    # Empty caps + a real (non-vm_internal) caller → no authorizer → denied.
    inv = ping_invocation(provider_uri, caller_uri, MapSet.new())

    state = %{receipt_fixture: %{}}

    assert {:error, :unauthorized} =
             Ezagent.Kind.Runtime.handle_dispatch(inv, state, ReceiptFixtureKind, provider_uri)

    assert receipt_rows(provider_uri) == [],
           "a denied dispatch must never emit a receipt"
  end

  test "a receipt-write failure is swallowed and never propagates", %{
    provider_uri: provider_uri,
    caller_uri: caller_uri
  } do
    # An un-JSON-encodable payload makes `EventLog.append`'s `Jason.encode!/1`
    # raise. `emit_receipt/3` (reusing the `:emit`-effect `execute_events` path)
    # must swallow it and still return `:ok` — the same return the dispatch
    # discards inside its `try`, so a receipt-write failure can never break or
    # slow the dispatch reply.
    bad_payload = %{caller: URI.to_string(caller_uri), unencodable: self()}

    ctx = %{caller: caller_uri, trace_id: nil}

    assert :ok = Ezagent.Kind.Runtime.Effects.emit_receipt(provider_uri, bad_payload, ctx)

    # Nothing was persisted (the append failed) — proving the failure path,
    # not a silent success.
    assert receipt_rows(provider_uri) == []
  end
end

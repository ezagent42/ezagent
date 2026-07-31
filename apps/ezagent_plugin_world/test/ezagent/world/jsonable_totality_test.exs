defmodule Ezagent.World.JsonableTotalityTest do
  @moduledoc """
  REGRESSION: `Ezagent.World.Jsonable.to_json/1` is the shared serialization
  boundary for the operator-observability streams (audit / cc_event /
  operator_event) that fan out to every connected operator LiveView. It MUST
  be total — never raise, always produce a `Jason.encode!`-able term — so a
  single malformed event cannot crash-loop those sockets.
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.Jsonable

  test "a non-string (tuple) map key is coerced, not raised on" do
    out = Jsonable.to_json(%{{:bad, :key} => 1})
    assert {:ok, json} = Jason.encode(out)
    assert json =~ "bad"
  end

  test "an invalid-UTF-8 binary value stays JSON-encodable" do
    out = Jsonable.to_json(%{message: <<255, 254>>})
    assert {:ok, _json} = Jason.encode(out)
  end

  test "a pid / ref anywhere in the payload is safe" do
    out = Jsonable.to_json(%{meta: %{pid: self(), ref: make_ref()}})
    assert {:ok, _json} = Jason.encode(out)
  end

  test "a well-formed operator event still serializes cleanly" do
    event = %{
      severity: :warning,
      source: :cap_delivery_outbox,
      message: "capability delivery permanently failed (dead)",
      meta: %{target_uri: "entity://team-alpha/agent/x"},
      at: DateTime.utc_now()
    }

    assert {:ok, json} = Jason.encode(Jsonable.to_json(event))
    assert json =~ "cap_delivery_outbox"
    assert json =~ "entity://team-alpha/agent/x"
  end
end

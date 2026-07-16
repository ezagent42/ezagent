defmodule Ezagent.InvocationActivateBudgetTest do
  @moduledoc """
  FP5 S5 (#115): the cold-activation budget for a synchronous dispatch awaiting
  a target's `activate/2`.

  The default budget was bumped from 5s → 20s because cold HEAVY flavors (a `cc`
  agent launches claude + scanner-clicks its startup dialogs) routinely need
  >5s to announce `:ready`. `Ezagent.Invocation.activate_budget_ms/0` is the
  single source for both `:call` await sites; it is `Application.get_env`-
  overridable so this test can drive the timeout path FAST (a tiny budget)
  rather than block for 20s.

  Two assertions:
   1. the default budget is 20s (the bump landed).
   2. a `:not_ready` target that never readies surfaces the DISTINCT
      `{:error, :activate_timeout}` (not `:not_ready`) — within the configured
      budget — proving the budget governs the await + the let-it-crash signal
      is preserved.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, ReadyGate}

  @scheme "resource"

  test "the default cold-activation budget is 20s (the #115 bump)" do
    # No override configured → the default constant.
    prev = Application.get_env(:ezagent_core, :activate_budget_ms)
    Application.delete_env(:ezagent_core, :activate_budget_ms)

    try do
      assert Invocation.activate_budget_ms() == 20_000
    after
      if prev, do: Application.put_env(:ezagent_core, :activate_budget_ms, prev)
    end
  end

  test "a :call to a never-readying target times out as :activate_timeout within the budget" do
    uri =
      Ezagent.URI.new!(
        "#{@scheme}://thing/team-alpha/budget-#{System.unique_integer([:positive])}"
      )

    # Force the stale-gate state the `{:not_ready, :call}` branch consumes: the
    # gate says :not_ready, no live pid will ever flip it. (Same direct-gate
    # technique as invocation_death_race_test, avoiding a real Kind.)
    :ok = ReadyGate.put(uri, :not_ready)

    # Drive the budget low so the await returns quickly; restore after.
    prev = Application.get_env(:ezagent_core, :activate_budget_ms)
    Application.put_env(:ezagent_core, :activate_budget_ms, 120)

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")

    inv = %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: Ezagent.URI.new!("entity://system/user/admin"),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    }

    try do
      {elapsed_us, result} = :timer.tc(fn -> Invocation.dispatch(inv) end)

      # DISTINCT signal — never the silent :not_ready (let-it-crash visibility).
      assert result == {:error, :activate_timeout}

      # Honored the SMALL configured budget (not the 20s default): well under 5s
      # proves the configurable budget governed the await.
      assert elapsed_us < 3_000_000
    after
      if prev,
        do: Application.put_env(:ezagent_core, :activate_budget_ms, prev),
        else: Application.delete_env(:ezagent_core, :activate_budget_ms)
    end
  end
end

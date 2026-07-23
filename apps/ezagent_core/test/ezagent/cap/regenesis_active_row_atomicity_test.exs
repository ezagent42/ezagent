defmodule Ezagent.Cap.RegenesisActiveRowAtomicityTest do
  @moduledoc """
  G-1/MF4 regression: `regenesis/2` retires generation N and inserts N+1 in
  one database transaction. The committed active row is the revocation point;
  `verify_against_current/3` must reject the old cap immediately, without any
  mutable URI-to-current cache invalidation.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindCapAuthority

  test "commit exposes exactly one new active row and immediately denies old generation" do
    target = unique_target()
    holder = unique_holder()
    {:ok, generation_one} = Authority.open(target, :test)

    old_cap =
      authority_signed_cap!(
        generation_one,
        holder,
        Capability.cap(
          :test,
          Ezagent.Test.TestBehavior,
          :noop,
          target,
          Capability.workspace_of(target)
        )
      )

    assert Authority.verify_against_current(old_cap, holder, target)
    assert {:ok, generation_two} = Authority.regenesis(target, :test)

    rows = KindCapAuthority.list(Ezagent.URI.stable_key(target))
    assert Enum.count(rows, & &1.active) == 1
    assert Enum.find(rows, & &1.active).generation == generation_two.generation
    assert generation_two.generation == generation_one.generation + 1

    refute Authority.verify_against_current(old_cap, holder, target)
  end

  defp unique_target do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/regenesis-atomic-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_holder do
    Ezagent.URI.new!(
      "entity://team-alpha/user/regenesis-holder-#{System.unique_integer([:positive])}"
    )
  end
end

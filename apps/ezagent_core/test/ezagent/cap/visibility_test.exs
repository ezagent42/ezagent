defmodule Ezagent.Cap.VisibilityTest do
  @moduledoc """
  URI-share unification (A2-1) — `Cap.Visibility.caps_toward/2`.

  The generic forward visibility derivation: given a cap set, list the concrete
  target instances the holder has caps toward for a given behavior — "what can I
  see of this kind". Generalizes kanban's private per-board derivation into a
  reusable, plugin-agnostic helper. Pure over `%Capability{}` structs (no store,
  no authorization) — the chokepoint stays `Cap.authorize`; this only enumerates.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.Cap.Visibility
  alias Ezagent.URI, as: EzURI

  defp cap(behavior, %URI{} = instance) do
    Capability.cap(
      :agent,
      behavior,
      :get_tree,
      EzURI.instance(instance),
      EzURI.new!("workspace://acme")
    )
  end

  @b1 Ezagent.ActionSet.ApiKeys
  @b2 Ezagent.ActionSet.Session
  @t1 EzURI.new!("entity://acme/agent/board-1")
  @t2 EzURI.new!("entity://acme/agent/board-2")

  test "returns the concrete target instances for the given behavior only" do
    caps = [cap(@b1, @t1), cap(@b1, @t2), cap(@b2, @t1)]
    got = Visibility.caps_toward(caps, @b1) |> Enum.map(&EzURI.stable_key/1) |> Enum.sort()

    want =
      [EzURI.stable_key(EzURI.instance(@t1)), EzURI.stable_key(EzURI.instance(@t2))]
      |> Enum.sort()

    assert got == want
    # b2 target is not included under b1.
    assert Visibility.caps_toward(caps, @b2) |> Enum.map(&EzURI.stable_key/1) ==
             [EzURI.stable_key(EzURI.instance(@t1))]
  end

  test "de-dupes multiple caps toward the same target (e.g. read + operate)" do
    read = cap(@b1, @t1)

    operate =
      Capability.cap(:agent, @b1, :add_node, EzURI.instance(@t1), EzURI.new!("workspace://acme"))

    assert Visibility.caps_toward([read, operate], @b1)
           |> Enum.map(&EzURI.stable_key/1) == [EzURI.stable_key(EzURI.instance(@t1))]
  end

  test "excludes wildcard / non-concrete instances (:any) — only real targets" do
    wildcard = Capability.cap(:agent, @b1, :any, :any, EzURI.new!("workspace://acme"))

    assert Visibility.caps_toward([wildcard, cap(@b1, @t1)], @b1)
           |> Enum.map(&EzURI.stable_key/1) == [EzURI.stable_key(EzURI.instance(@t1))]
  end

  test "accepts a MapSet as well as a list; empty → []" do
    assert Visibility.caps_toward(MapSet.new([cap(@b1, @t1)]), @b1)
           |> Enum.map(&EzURI.stable_key/1) == [EzURI.stable_key(EzURI.instance(@t1))]

    assert Visibility.caps_toward([], @b1) == []
    assert Visibility.caps_toward(MapSet.new(), @b1) == []
  end
end

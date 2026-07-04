defmodule Ezagent.Session.ReceiveAuthzParityTest do
  @moduledoc """
  Membership-cap unification A2.1 / spec test 24 (corrected by R2.3) — the
  RECEIVE-authz parity gate.

  Enumerates the ACTUAL registered `{Kind, :receive}` behaviors DYNAMICALLY from
  the `BehaviorRegistry` (the same source the required-caps parity gates use —
  today exactly `User.Receive` + `Agent.Receive`; dispatch is registry-first per
  `behavior_set.ex`), and asserts EACH one:

    1. makes `:receive` a `cap_exempt_action` (the CapBAC layer does NOT gate it
       via the caller-scoped mismatch — the HANDLER is the sole authority), AND
    2. routes its `handle_receive/2` through the ONE shared predicate
       `Ezagent.Session.MemberReceive.authorize/1`.

  Because it reads the registry, a FUTURE Kind that registers a real
  `{Kind, :receive}` is caught automatically: a new plugin receive that skips
  the shared predicate (or forgets `cap_exempt`) fails this gate. It does NOT
  enumerate the unreachable `HelloBuilder` / `HelloConcierge` role `:receive`
  handlers (those never run — plugin agents receive THROUGH `Agent.Receive`;
  R2.3).
  """

  use ExUnit.Case, async: true

  defp registered_receive_behaviors do
    for {{kind, :receive}, mod} <- Ezagent.BehaviorRegistry.list_all(), do: {kind, mod}
  end

  test "there is at least one registered {Kind, :receive} behavior (sanity)" do
    behaviors = registered_receive_behaviors()

    assert Enum.any?(behaviors),
           "expected at least User.Receive + Agent.Receive to be registered for {_, :receive}"
  end

  test "every registered {Kind, :receive} behavior makes :receive cap_exempt" do
    for {kind, mod} <- registered_receive_behaviors() do
      assert function_exported?(mod, :cap_exempt_actions, 0),
             "#{inspect(mod)} (for {#{inspect(kind)}, :receive}) must export cap_exempt_actions/0"

      assert :receive in mod.cap_exempt_actions(),
             "#{inspect(mod)} (for {#{inspect(kind)}, :receive}) must make :receive cap_exempt " <>
               "(the in-handler MemberReceive.authorize/1 is the sole authority)"
    end
  end

  test "every registered {Kind, :receive} behavior routes through MemberReceive.authorize/1" do
    for {kind, mod} <- registered_receive_behaviors() do
      assert routes_through_member_receive_authorize?(mod),
             "#{inspect(mod)} (for {#{inspect(kind)}, :receive}) must authorize via " <>
               "Ezagent.Session.MemberReceive.authorize/1 in its handle_receive/2"
    end
  end

  # Static source check: the module's compiled-from source file must reference
  # `MemberReceive.authorize`. A source-grep (not a behavioral probe) so the gate
  # is deterministic and catches a NEW receive behavior that omits the call
  # regardless of how its handler is shaped.
  defp routes_through_member_receive_authorize?(mod) do
    with source when is_list(source) <- mod.module_info(:compile)[:source],
         path = List.to_string(source),
         {:ok, body} <- File.read(path) do
      String.contains?(body, "MemberReceive.authorize")
    else
      _ -> false
    end
  end
end

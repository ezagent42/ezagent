defmodule Ezagent.Kind.ServerSignalEnvelopeTest do
  @moduledoc """
  V5 use-side B2 — the `Kind.Server.handle_info/2` ENABLER clause: a
  `%EzagentActor.Signal{}` envelope is unwrapped to its effective raw
  message and re-dispatched through the SAME existing clauses (named +
  catch-all + behavior forwarding), so every consumer runs UNCHANGED.

  These tests pin the ADDITIVE contract: envelope delivery is transparent
  to the existing handlers, and nothing is sealed (raw messages still
  dispatch identically).
  """
  use ExUnit.Case, async: false

  alias Ezagent.Kind.Server
  alias EzagentActor.Signal

  defmodule FakeAuthority do
    @moduledoc false
    def with_authority(_authority, fun), do: fun.()
  end

  defmodule RecordingBehavior do
    @moduledoc false
    # Legacy-callback behavior (`handle_kind_message/3`) that reports every
    # mailbox message it is forwarded back to the test pid (threaded
    # through its own slice).
    def state_slice, do: :recording

    def handle_kind_message(message, %{test_pid: test_pid}, _ctx) do
      send(test_pid, {:behavior_saw, message})
      :ignore
    end

    def handle_kind_message(_message, _slice, _ctx), do: :ignore
  end

  defmodule StubKind do
    @moduledoc false
    def behaviors, do: [RecordingBehavior]
    def persistence, do: :ephemeral
  end

  setup do
    Application.put_env(:ezagent_actor, :authority, FakeAuthority)
    on_exit(fn -> Application.delete_env(:ezagent_actor, :authority) end)

    wrapper = %{
      kind: StubKind,
      uri: URI.parse("entity://test/agent/signal-envelope-#{System.unique_integer([:positive])}"),
      state: %{
        kind_base: %{state: %{behaviors: [RecordingBehavior]}, transients: %{}},
        recording: %{test_pid: self()}
      },
      authority: :fake
    }

    %{wrapper: wrapper}
  end

  describe "envelope → named clause re-dispatch" do
    test "%Signal{kind: :signal, payload: :snapshot_tick} re-dispatches into the :snapshot_tick clause",
         %{wrapper: wrapper} do
      envelope = %Signal{kind: :signal, payload: :snapshot_tick}

      assert Server.handle_info(envelope, wrapper) ==
               Server.handle_info(:snapshot_tick, wrapper)

      assert {:noreply, ^wrapper} = Server.handle_info(envelope, wrapper)
    end

    test "%Signal{kind: :timer, payload: :snapshot_tick} (Signal.send_after/2 shape) also re-dispatches",
         %{wrapper: wrapper} do
      envelope = %Signal{kind: :timer, from: self(), payload: :snapshot_tick}

      assert {:noreply, ^wrapper} = Server.handle_info(envelope, wrapper)
    end
  end

  describe "envelope → catch-all behavior forwarding" do
    test "a :down envelope reconstructs the raw {:DOWN, …} tuple for the behavior UNCHANGED",
         %{wrapper: wrapper} do
      ref = make_ref()
      pid = self()

      envelope = %Signal{
        kind: :down,
        from: pid,
        payload: %{ref: ref, pid: pid, reason: :killed}
      }

      assert {:noreply, _} = Server.handle_info(envelope, wrapper)
      assert_received {:behavior_saw, {:DOWN, ^ref, :process, ^pid, :killed}}
    end

    test "the :down envelope dispatches IDENTICALLY to the raw {:DOWN, …} message",
         %{wrapper: wrapper} do
      ref = make_ref()
      pid = self()
      raw = {:DOWN, ref, :process, pid, :noproc}
      envelope = %Signal{kind: :down, from: pid, payload: %{ref: ref, pid: pid, reason: :noproc}}

      assert Server.handle_info(envelope, wrapper) == Server.handle_info(raw, wrapper)
    end

    test "any other envelope unwraps to its payload verbatim", %{wrapper: wrapper} do
      envelope = %Signal{kind: :signal, payload: {:publisher_event, :some_event}}

      assert {:noreply, _} = Server.handle_info(envelope, wrapper)
      assert_received {:behavior_saw, {:publisher_event, :some_event}}
    end

    test "ADDITIVE (nothing sealed): a raw message still reaches the behavior as before",
         %{wrapper: wrapper} do
      assert {:noreply, _} = Server.handle_info({:publisher_event, :raw}, wrapper)
      assert_received {:behavior_saw, {:publisher_event, :raw}}
    end
  end
end

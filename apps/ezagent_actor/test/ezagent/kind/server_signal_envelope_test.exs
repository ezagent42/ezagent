defmodule Ezagent.Kind.ServerSignalEnvelopeTest do
  @moduledoc """
  V5 use-side H3 — THE SEAL. `Kind.Server.handle_info/2` now accepts ONLY
  `%EzagentActor.Signal{}` envelopes (routed to the private
  `dispatch_sanctioned/2` router, NEVER re-dispatched through
  `handle_info/2`) and VM-generated `{:EXIT, pid, reason}` tuples (observe-
  only lifecycle clause). Everything else FAILS LOUD: in `:dev`/`:test` it
  raises `Ezagent.Kind.UnsanctionedMailboxError` (the migration completeness
  proof); in `:prod` it logs + emits `[:ezagent, :kind, :unsanctioned_mailbox]`
  telemetry and drops. The non-sanctioned call/cast doors reply
  `{:error, :unsanctioned}` / drop loudly — never the pre-seal
  `FunctionClauseError` that killed the Kind.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Kind.Server
  alias Ezagent.Kind.UnsanctionedMailboxError
  alias EzagentActor.Signal

  @unsanctioned_event [:ezagent, :kind, :unsanctioned_mailbox]

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

    test_pid = self()
    handler_id = "seal-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      @unsanctioned_event,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:unsanctioned_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    wrapper = %{
      kind: StubKind,
      uri: URI.parse("entity://test/agent/seal-#{System.unique_integer([:positive])}"),
      state: %{
        kind_base: %{state: %{behaviors: [RecordingBehavior]}, transients: %{}},
        recording: %{test_pid: self()}
      },
      authority: :fake
    }

    %{wrapper: wrapper}
  end

  describe "sanctioned envelope → private dispatch_sanctioned router" do
    test "%Signal{kind: :signal, payload: :snapshot_tick} routes to the snapshot_tick handling",
         %{wrapper: wrapper} do
      envelope = %Signal{kind: :signal, payload: :snapshot_tick}

      assert {:noreply, ^wrapper} = Server.handle_info(envelope, wrapper)
    end

    test "%Signal{kind: :timer, payload: :snapshot_tick} (Signal.send_after/2 shape) routes too",
         %{wrapper: wrapper} do
      envelope = %Signal{kind: :timer, from: self(), payload: :snapshot_tick}

      assert {:noreply, ^wrapper} = Server.handle_info(envelope, wrapper)
    end

    test "%Signal{kind: :signal, payload: {:ezagent_external_ready_gate, _, _}} routes to the framework verb",
         %{wrapper: wrapper} do
      envelope = %Signal{
        kind: :signal,
        payload: {:ezagent_external_ready_gate, "entity://test/agent/none", {:error, :timeout}}
      }

      assert {:noreply, ^wrapper} = Server.handle_info(envelope, wrapper)
    end

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

    test "any other envelope unwraps to its payload verbatim for the behavior",
         %{wrapper: wrapper} do
      envelope = %Signal{kind: :signal, payload: {:publisher_event, :some_event}}

      assert {:noreply, _} = Server.handle_info(envelope, wrapper)
      assert_received {:behavior_saw, {:publisher_event, :some_event}}
    end
  end

  describe "THE SEAL — raw (non-sanctioned) handle_info FAILS LOUD" do
    test "has teeth: a raw send-equivalent `{:junk}` RAISES UnsanctionedMailboxError",
         %{wrapper: wrapper} do
      assert_raise UnsanctionedMailboxError, fn ->
        Server.handle_info({:junk}, wrapper)
      end

      assert_received {:unsanctioned_telemetry, @unsanctioned_event, %{count: 1},
                       %{door: :handle_info, kind: StubKind, shape: {:junk, 1}}}

      refute_received {:behavior_saw, _}
    end

    test "a genuinely-unknown atom RAISES loud in dev/test", %{wrapper: wrapper} do
      assert_raise UnsanctionedMailboxError, fn ->
        Server.handle_info(:sys_style_unknown_atom, wrapper)
      end

      assert_received {:unsanctioned_telemetry, @unsanctioned_event, %{count: 1},
                       %{door: :handle_info, shape: :sys_style_unknown_atom}}
    end

    test "a raw framework verb (un-enveloped :snapshot_tick) RAISES — producers must ride Signal",
         %{wrapper: wrapper} do
      assert_raise UnsanctionedMailboxError, fn ->
        Server.handle_info(:snapshot_tick, wrapper)
      end
    end

    test "a raw {:DOWN, …} (un-migrated Process.monitor/1) RAISES — must ride Signal.monitor/1",
         %{wrapper: wrapper} do
      assert_raise UnsanctionedMailboxError, fn ->
        Server.handle_info({:DOWN, make_ref(), :process, self(), :noproc}, wrapper)
      end

      refute_received {:behavior_saw, _}
    end

    test "the raise names the offending term + the Kind uri/kind", %{wrapper: wrapper} do
      error =
        assert_raise UnsanctionedMailboxError, fn ->
          Server.handle_info({:junk, 42}, wrapper)
        end

      assert error.door == :handle_info
      assert error.uri == wrapper.uri
      assert error.kind == StubKind
      assert error.offending_term == {:junk, 42}
      assert Exception.message(error) =~ "{:junk, 42}"
      assert Exception.message(error) =~ "SEALED"
    end
  end

  describe "VM-generated {:EXIT, pid, reason} — explicit framework lifecycle clause" do
    test "is observed + ignored (NO raise, NO behavior forward, NO persist)",
         %{wrapper: wrapper} do
      assert {:noreply, ^wrapper} = Server.handle_info({:EXIT, self(), :killed}, wrapper)

      refute_received {:behavior_saw, _}
      refute_received {:unsanctioned_telemetry, _, _, _}
    end
  end

  describe "THE SEAL — call/cast doors return observable errors, never crash the Kind" do
    test "a non-sanctioned handle_call replies {:error, :unsanctioned} + loud telemetry",
         %{wrapper: wrapper} do
      assert {:reply, {:error, :unsanctioned}, ^wrapper} =
               Server.handle_call({:totally_unknown_verb, 1}, self(), wrapper)

      assert_received {:unsanctioned_telemetry, @unsanctioned_event, %{count: 1},
                       %{door: :handle_call, shape: {:totally_unknown_verb, 2}}}
    end

    test "a non-sanctioned handle_cast is dropped loudly (no Kind crash)",
         %{wrapper: wrapper} do
      assert {:noreply, ^wrapper} = Server.handle_cast({:totally_unknown_verb, 1}, wrapper)

      assert_received {:unsanctioned_telemetry, @unsanctioned_event, %{count: 1},
                       %{door: :handle_cast, shape: {:totally_unknown_verb, 2}}}
    end

    test "sanctioned framework call-verbs are NOT drift — :ezagent_get_slice still works",
         %{wrapper: wrapper} do
      assert {:reply, {:ok, %{test_pid: _}}, ^wrapper} =
               Server.handle_call({:ezagent_get_slice, :recording}, self(), wrapper)

      refute_received {:unsanctioned_telemetry, _, _, _}
    end
  end
end

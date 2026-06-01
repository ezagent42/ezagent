defmodule Ezagent.EventSubscriberTest do
  @moduledoc """
  Phase 1B SPEC §5.5 — `Ezagent.EventSubscriber` macro + behaviour
  + catalogue.

  Tests cover:

  1. The `subscribe/1` macro captures `:to` + `:only` on the module
  2. `:to` validates allowed shapes (`:all | {:aggregate, _} | {:workspace, _}`)
  3. `:only` defaults to `:any` and validates list entries
  4. `register/1` records the subscriber in the catalogue (idempotent)
  5. `list/0` + `lookup/1` reflect registered subscribers
  6. Callbacks `interested?/1` + `handle_event/2` dispatch via mock
  7. The `@behaviour` is enforced — calling `register/1` on a non-using
     module raises ArgumentError
  """

  use ExUnit.Case

  alias Ezagent.EventSubscriber

  # ---------------------------------------------------------------------
  # Fixture subscribers (declared at compile-time)
  # ---------------------------------------------------------------------

  defmodule AllEventsSubscriber do
    use Ezagent.EventSubscriber

    subscribe to: :all, only: [:message_sent, :binding_created]

    @impl true
    def interested?(%{event_name: "message_sent"}), do: true
    def interested?(_), do: false

    @impl true
    def handle_event(event, state) do
      # Echo into the calling test's mailbox so we can assert dispatch.
      send(state.caller, {:event_handled, event.event_name})
      {[], state}
    end
  end

  defmodule AggregateScopedSubscriber do
    use Ezagent.EventSubscriber

    subscribe to: {:aggregate, "entity://agent/team-alpha/test_subscriber"}

    @impl true
    def interested?(_), do: true

    @impl true
    def handle_event(_event, state), do: {:ok, state}
  end

  defmodule WorkspaceScopedSubscriber do
    use Ezagent.EventSubscriber

    subscribe to: {:workspace, "workspace://team-alpha"}, only: [:binding_created]

    @impl true
    def interested?(_), do: true

    @impl true
    def handle_event(_event, _state), do: :ok
  end

  defmodule NoSubscribeCall do
    # Demonstrates that `register/1` rejects a module that never
    # called `subscribe/1`. NB: `use Ezagent.EventSubscriber` alone
    # does NOT register anything (no @ezagent_event_subscription set).
    use Ezagent.EventSubscriber

    @impl true
    def interested?(_), do: false

    @impl true
    def handle_event(_event, state), do: {:ok, state}
  end

  # ---------------------------------------------------------------------
  # Test setup — reset catalogue each test so registrations don't leak.
  # ---------------------------------------------------------------------

  setup do
    # First access creates the ETS table; reset wipes any prior test's rows.
    :ok = EventSubscriber.__reset__()
    :ok
  end

  describe "subscribe/1 macro" do
    test "captures :to + :only on the module" do
      assert %{to: :all, only: [:message_sent, :binding_created]} =
               AllEventsSubscriber.__ezagent_event_subscription__()
    end

    test "supports {:aggregate, uri} scope" do
      assert %{to: {:aggregate, "entity://agent/team-alpha/test_subscriber"}} =
               AggregateScopedSubscriber.__ezagent_event_subscription__()
    end

    test "supports {:workspace, uri} scope" do
      assert %{to: {:workspace, "workspace://team-alpha"}, only: [:binding_created]} =
               WorkspaceScopedSubscriber.__ezagent_event_subscription__()
    end

    test ":only defaults to :any when omitted" do
      assert %{only: :any} = AggregateScopedSubscriber.__ezagent_event_subscription__()
    end
  end

  describe "subscribe/1 validation" do
    test "rejects missing :to" do
      assert_raise ArgumentError, ~r/:to is required/, fn ->
        EventSubscriber.__validate_subscribe__!(only: [:foo])
      end
    end

    test "rejects an unknown :to shape" do
      assert_raise ArgumentError, ~r/:to must be :all/, fn ->
        EventSubscriber.__validate_subscribe__!(to: :everything)
      end
    end

    test "rejects an :only entry that is neither atom nor string" do
      assert_raise ArgumentError, ~r/:only entries must/, fn ->
        EventSubscriber.__validate_subscribe__!(to: :all, only: [123])
      end
    end

    test "rejects a non-keyword arg" do
      assert_raise ArgumentError, ~r/expected keyword opts/, fn ->
        EventSubscriber.__validate_subscribe__!(%{to: :all})
      end
    end
  end

  describe "register/1 + list/0 + lookup/1" do
    test "register/1 records the module's subscription" do
      :ok = EventSubscriber.register(AllEventsSubscriber)

      assert {:ok, %{to: :all, only: [:message_sent, :binding_created]}} =
               EventSubscriber.lookup(AllEventsSubscriber)
    end

    test "register/1 is idempotent" do
      :ok = EventSubscriber.register(AllEventsSubscriber)
      :ok = EventSubscriber.register(AllEventsSubscriber)

      assert length(EventSubscriber.list()) == 1
    end

    test "list/0 returns all registered subscribers" do
      :ok = EventSubscriber.register(AllEventsSubscriber)
      :ok = EventSubscriber.register(WorkspaceScopedSubscriber)

      mods = EventSubscriber.list() |> Enum.map(fn {m, _} -> m end) |> Enum.sort()
      assert mods == Enum.sort([AllEventsSubscriber, WorkspaceScopedSubscriber])
    end

    test "lookup/1 returns :error for an unregistered module" do
      assert EventSubscriber.lookup(AggregateScopedSubscriber) == :error
    end

    test "register/1 rejects a module that never called subscribe/1" do
      assert_raise ArgumentError, ~r/did not call `subscribe\/1`/, fn ->
        EventSubscriber.register(NoSubscribeCall)
      end
    end
  end

  describe "callbacks dispatch via mock" do
    test "interested?/1 + handle_event/2 are callable and route through state" do
      event = %{
        event_id: 42,
        aggregate_uri: "entity://agent/team-alpha/x",
        event_name: "message_sent",
        payload: %{},
        caller: nil,
        workspace_uri: "workspace://team-alpha",
        trace_id: nil,
        inserted_at: DateTime.utc_now()
      }

      assert AllEventsSubscriber.interested?(event)

      refute AllEventsSubscriber.interested?(%{event | event_name: "other"})

      state = %{caller: self()}
      assert {[], ^state} = AllEventsSubscriber.handle_event(event, state)
      assert_receive {:event_handled, "message_sent"}, 100
    end
  end
end

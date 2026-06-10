defmodule Ezagent.UI.SessionViewRegistryTest do
  use ExUnit.Case, async: false

  alias Ezagent.UI.SessionViewRegistry

  # Stub views for the test only — declared inline so we don't need
  # a real plugin to drive the registry behaviours.
  defmodule StubChatView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :stub_chat

    @impl true
    def label, do: "Chat"

    @impl true
    def icon, do: "message-square"

    @impl true
    def applies_to?(_session_uri), do: true

    @impl true
    def render(assigns), do: ~H"<div>stub chat</div>"
  end

  defmodule StubPtyView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :stub_pty

    @impl true
    def label, do: "Terminal"

    @impl true
    def icon, do: "terminal"

    @impl true
    def applies_to?(session_uri) do
      # Returns true iff the session_uri path mentions "pty".
      String.contains?(URI.to_string(session_uri), "pty")
    end

    @impl true
    def render(assigns), do: ~H"<div>stub pty</div>"
  end

  defmodule CrashyView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :stub_crashy

    @impl true
    def label, do: "Crashy"

    @impl true
    def icon, do: "bug"

    @impl true
    def applies_to?(_uri), do: raise "boom"

    @impl true
    def render(assigns), do: ~H"<div>nope</div>"
  end

  defmodule StubExternalView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :stub_external

    @impl true
    def label, do: "External"

    @impl true
    def icon, do: "globe"

    @impl true
    def applies_to?(_session_uri), do: true

    @impl true
    def render(assigns), do: ~H"<div>stub external internal render</div>"

    @impl true
    def external_render?, do: true

    @impl true
    def external_render(_session_uri), do: %{type: "container", children: []}
  end

  # codex P2 review HIGH — a HALF-DECLARED view: declares `external_render?/0 =>
  # true` but OMITS `external_render/1`. The registry MUST NOT publish it as an
  # external renderer (else the future ExternalAdapter crashes invoking the
  # missing `external_render/1`).
  defmodule StubHalfDeclaredExternalView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :stub_half_declared

    @impl true
    def label, do: "Half"

    @impl true
    def icon, do: "globe"

    @impl true
    def applies_to?(_session_uri), do: true

    @impl true
    def render(assigns), do: ~H"<div>half-declared internal render</div>"

    @impl true
    def external_render?, do: true

    # external_render/1 intentionally NOT implemented.
  end

  setup do
    SessionViewRegistry.init()

    # Clean slate for each test — drop any entries left by previous tests
    # so assertions on registry contents are stable.
    on_exit(fn ->
      try do
        :ets.delete_all_objects(SessionViewRegistry.table())
      catch
        _, _ -> :ok
      end
    end)

    :ets.delete_all_objects(SessionViewRegistry.table())
    :ok
  end

  describe "init/0" do
    test "is idempotent — second call does not raise" do
      assert :ok = SessionViewRegistry.init()
      assert :ok = SessionViewRegistry.init()
    end
  end

  describe "register/1 + lookup/1 round trip" do
    test "register then lookup returns the same module" do
      :ok = SessionViewRegistry.register(StubChatView)
      assert {:ok, StubChatView} = SessionViewRegistry.lookup(:stub_chat)
    end

    test "lookup of unregistered id returns :error" do
      assert :error = SessionViewRegistry.lookup(:never_registered)
    end
  end

  describe "applicable_views/1" do
    test "returns only views whose applies_to?/1 returns true" do
      :ok = SessionViewRegistry.register(StubChatView)
      :ok = SessionViewRegistry.register(StubPtyView)

      uri = URI.new!("session://system/default/main")
      views = SessionViewRegistry.applicable_views(uri)

      ids = Enum.map(views, & &1.id)
      assert :stub_chat in ids
      refute :stub_pty in ids
    end

    test "includes views whose applies_to?/1 returns true for given session" do
      :ok = SessionViewRegistry.register(StubChatView)
      :ok = SessionViewRegistry.register(StubPtyView)

      uri = URI.new!("session://team-alpha/default/pty-friendly")
      views = SessionViewRegistry.applicable_views(uri)

      ids = Enum.map(views, & &1.id)
      assert :stub_chat in ids
      assert :stub_pty in ids
    end

    test "sorts by id" do
      :ok = SessionViewRegistry.register(StubPtyView)
      :ok = SessionViewRegistry.register(StubChatView)

      uri = URI.new!("session://team-alpha/default/pty-friendly")
      views = SessionViewRegistry.applicable_views(uri)
      ids = Enum.map(views, & &1.id)

      assert ids == Enum.sort(ids)
    end

    test "a crashy applies_to?/1 callback is treated as false (does not propagate)" do
      :ok = SessionViewRegistry.register(StubChatView)
      :ok = SessionViewRegistry.register(CrashyView)

      uri = URI.new!("session://system/default/main")
      views = SessionViewRegistry.applicable_views(uri)
      ids = Enum.map(views, & &1.id)

      assert :stub_chat in ids
      refute :stub_crashy in ids
    end

    test "each returned view has id, label, icon, module keys" do
      :ok = SessionViewRegistry.register(StubChatView)
      uri = URI.new!("session://system/default/main")
      [view] = SessionViewRegistry.applicable_views(uri)

      assert %{id: :stub_chat, label: "Chat", icon: "message-square", module: StubChatView} = view
    end
  end

  describe "external_render?/1" do
    test "is true for a view declaring external_render?/0 => true" do
      assert SessionViewRegistry.external_render?(StubExternalView) == true
    end

    test "is false for an internal-only view (no external_render?/0)" do
      assert SessionViewRegistry.external_render?(StubChatView) == false
    end

    test "is false for a HALF-DECLARED view: external_render?/0 true but no external_render/1 (codex P2 HIGH)" do
      assert SessionViewRegistry.external_render?(StubHalfDeclaredExternalView) == false
    end
  end

  describe "external_renderers/1" do
    test "returns only views that declare an external render for the session" do
      :ok = SessionViewRegistry.register(StubChatView)
      :ok = SessionViewRegistry.register(StubExternalView)

      uri = URI.new!("session://system/default/main")
      views = SessionViewRegistry.external_renderers(uri)
      ids = Enum.map(views, & &1.id)

      assert :stub_external in ids
      refute :stub_chat in ids
    end

    test "excludes an external view whose applies_to?/1 is false for the session" do
      defmodule StubExternalPtyOnly do
        @behaviour Ezagent.UI.SessionView
        use Phoenix.Component
        @impl true
        def id, do: :stub_external_pty
        @impl true
        def label, do: "ExtPty"
        @impl true
        def icon, do: "globe"
        @impl true
        def applies_to?(session_uri),
          do: String.contains?(URI.to_string(session_uri), "pty")
        @impl true
        def render(assigns), do: ~H"<div>x</div>"
        @impl true
        def external_render?, do: true
        @impl true
        def external_render(_uri), do: %{type: "container", children: []}
      end

      :ok = SessionViewRegistry.register(StubExternalPtyOnly)

      uri = URI.new!("session://system/default/main")
      ids = Enum.map(SessionViewRegistry.external_renderers(uri), & &1.id)
      refute :stub_external_pty in ids
    end

    test "each returned view exposes id, label, icon, module keys" do
      :ok = SessionViewRegistry.register(StubExternalView)
      uri = URI.new!("session://system/default/main")
      [view] = SessionViewRegistry.external_renderers(uri)

      assert %{id: :stub_external, label: "External", icon: "globe", module: StubExternalView} =
               view
    end
  end

  describe "all_ids/0" do
    test "returns sorted list of registered ids" do
      :ok = SessionViewRegistry.register(StubPtyView)
      :ok = SessionViewRegistry.register(StubChatView)
      assert SessionViewRegistry.all_ids() == [:stub_chat, :stub_pty]
    end
  end
end

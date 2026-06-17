defmodule EzagentPluginContent.Behavior.ContentAdminTest do
  @moduledoc """
  Tests for `ContentAdmin` Behavior — verify dispatch through
  `Invocation.dispatch/1` + CapBAC enforcement.

  ContentAdmin is STATELESS (no slice, no `behaviors/0` entry on
  Workspace Kind). Registration is via `CapabilityRegistry.register/3`
  only, which populates `BehaviorRegistry` automatically.

  Each action is tested for:
  - Happy path (admin caps → `{:ok, result}`)
  - CapBAC denial (empty caps → `{:error, :unauthorized}`)
  """

  use ExUnit.Case, async: false

  alias Ezagent.Invocation
  alias EzagentPluginContent.Behavior.ContentAdmin

  @test_ws "test-content-admin"
  @test_role "customer"

  setup_all do
    # Spawn the Workspace Kind once so dispatch has a target
    ws_uri = Ezagent.URI.workspace(@test_ws)

    case Ezagent.KindRegistry.lookup(ws_uri) do
      {:ok, _pid} -> :ok
      :error -> {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Workspace, %{uri: ws_uri})
    end

    {:ok, ws_uri: ws_uri}
  end

  setup do
    # Register before each test — ExUnit may shuffle test files, and
    # ETS tables are shared. Idempotent on repeat.
    ws_kind = Ezagent.Entity.Workspace

    Enum.each(Ezagent.Behavior.Introspection.action_names(ContentAdmin), fn action ->
      Ezagent.CapabilityRegistry.register(ws_kind, action, ContentAdmin)
    end)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)

    # Allow the Workspace Kind process to share the test's DB connection
    # (CrEngine.ensure_active_cr/1 writes to ConfigStore via Ecto).
    case Ezagent.KindRegistry.lookup(Ezagent.URI.workspace(@test_ws)) do
      {:ok, ws_pid} -> Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), ws_pid)
      :error -> :ok
    end

    # Override tenant_base_dir to a temp directory
    tmp = Path.join(System.tmp_dir!(), "ca_test_#{System.unique_integer()}")
    prev = Application.get_env(:ezagent_plugin_content, :tenant_base_dir)
    Application.put_env(:ezagent_plugin_content, :tenant_base_dir, tmp)

    sandbox = Path.join([tmp, @test_ws, "sandbox"])
    File.mkdir_p!(Path.join(sandbox, "slots"))
    File.mkdir_p!(Path.join([sandbox, "skills", @test_role]))
    File.mkdir_p!(Path.join(sandbox, "kb"))

    on_exit(fn ->
      if prev, do: Application.put_env(:ezagent_plugin_content, :tenant_base_dir, prev)
      File.rm_rf!(tmp)
    end)
  end

  # ---- Helpers ----

  defp admin_ctx do
    %{
      caller: Ezagent.URI.system(:bootstrap, :default),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
      reply: {:caller_inbox, self()}
    }
  end

  defp no_cap_ctx do
    %{
      caller: Ezagent.URI.new!("entity://test/user/no-caps"),
      caps: MapSet.new(),
      reply: {:caller_inbox, self()}
    }
  end

  defp target(ws_uri, action) do
    Ezagent.URI.with_action(ws_uri, :content_admin, action)
  end

  # ---- write_soul_slot ----

  describe "write_soul_slot" do
    test "writes a soul slot value via dispatch", %{ws_uri: ws_uri} do
      slot_key = "test_key_#{System.unique_integer([:positive])}"

      assert {:ok, _result} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "write_soul_slot"),
                 mode: :call,
                 args: %{role: @test_role, key: slot_key, value: "test-value"},
                 ctx: admin_ctx()
               })
    end

    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "write_soul_slot"),
                 mode: :call,
                 args: %{role: @test_role, key: "key", value: "val"},
                 ctx: no_cap_ctx()
               })
    end
  end

  # ---- write_skill ----

  describe "write_skill" do
    test "writes a skill via dispatch", %{ws_uri: ws_uri} do
      skill_name = "test-skill-#{System.unique_integer([:positive])}"

      assert {:ok, _result} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "write_skill"),
                 mode: :call,
                 args: %{role: @test_role, name: skill_name, content: "# Test Skill\n\nHello."},
                 ctx: admin_ctx()
               })
    end

    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "write_skill"),
                 mode: :call,
                 args: %{role: @test_role, name: "sk", content: "content"},
                 ctx: no_cap_ctx()
               })
    end
  end

  # ---- delete_skill / upsert_kb / delete_kb / publish_cr ----
  # CapBAC denial tests — ensure each action gates on caps.

  describe "delete_skill" do
    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "delete_skill"),
                 mode: :call,
                 args: %{role: @test_role, name: "nonexistent"},
                 ctx: no_cap_ctx()
               })
    end
  end

  describe "upsert_kb" do
    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "upsert_kb"),
                 mode: :call,
                 args: %{entry: %{"id" => "test-1", "content" => "test"}},
                 ctx: no_cap_ctx()
               })
    end
  end

  describe "delete_kb" do
    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "delete_kb"),
                 mode: :call,
                 args: %{id: "nonexistent"},
                 ctx: no_cap_ctx()
               })
    end
  end

  describe "publish_cr" do
    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "publish_cr"),
                 mode: :call,
                 args: %{},
                 ctx: no_cap_ctx()
               })
    end
  end

  # ---- preview_sandbox ----

  describe "preview_sandbox" do
    test "creates a preview session via dispatch", %{ws_uri: ws_uri} do
      assert {:ok, result} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "preview_sandbox"),
                 mode: :call,
                 args: %{role: @test_role},
                 ctx: admin_ctx()
               })

      assert %URI{scheme: "session"} = result.session_uri
      assert is_binary(result.work_dir)
    end

    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "preview_sandbox"),
                 mode: :call,
                 args: %{role: @test_role},
                 ctx: no_cap_ctx()
               })
    end
  end

  # ---- Re-route Phase 0: create_skill / write_fast_prompt / rebuild_kb / revert_item ----

  describe "create_skill" do
    test "creates a skill via dispatch", %{ws_uri: ws_uri} do
      name = "new-skill-#{System.unique_integer([:positive])}"

      assert {:ok, _result} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "create_skill"),
                 mode: :call,
                 args: %{role: @test_role, name: name},
                 ctx: admin_ctx()
               })
    end

    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "create_skill"),
                 mode: :call,
                 args: %{role: @test_role, name: "sk"},
                 ctx: no_cap_ctx()
               })
    end
  end

  describe "write_fast_prompt" do
    test "writes the fast ACK prompt via dispatch", %{ws_uri: ws_uri} do
      assert {:ok, _result} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "write_fast_prompt"),
                 mode: :call,
                 args: %{content: "您好,正在为您接入..."},
                 ctx: admin_ctx()
               })
    end

    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "write_fast_prompt"),
                 mode: :call,
                 args: %{content: "x"},
                 ctx: no_cap_ctx()
               })
    end
  end

  describe "rebuild_kb" do
    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "rebuild_kb"),
                 mode: :call,
                 args: %{},
                 ctx: no_cap_ctx()
               })
    end
  end

  describe "revert_item" do
    test "returns :unauthorized with no caps", %{ws_uri: ws_uri} do
      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: target(ws_uri, "revert_item"),
                 mode: :call,
                 args: %{path: "skills/customer/x/SKILL.md"},
                 ctx: no_cap_ctx()
               })
    end
  end

  # ---- Non-workspace dispatch ----

  describe "non-workspace dispatch" do
    test "returns :no_such_actor when dispatching against non-existent session URI" do
      non_ws_target =
        Ezagent.URI.with_action(
          Ezagent.URI.new!("session://cs/test/foo"),
          :content_admin,
          :write_soul_slot
        )

      assert {:error, :no_such_actor} =
               Invocation.dispatch(%Invocation{
                 target: non_ws_target,
                 mode: :call,
                 args: %{role: @test_role, key: "k", value: "v"},
                 ctx: admin_ctx()
               })
    end
  end
end

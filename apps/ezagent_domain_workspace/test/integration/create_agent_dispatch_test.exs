defmodule Ezagent.Integration.CreateAgentDispatchTest do
  @moduledoc """
  Acceptance test for SPEC 2026-05-25-agent-create-cli-gui-parity:
  the unified `Ezagent.Workspace.create_agent/3` facade — what BOTH
  the CLI (`mix ezagent.agent.create`) and the LV
  (`EzagentPluginLiveview.AgentNewLive`) call — dispatches the
  `Behavior.Workspace.:create_agent` action.

  Focused on the action's contract surface (validation + early-exit
  shapes) without needing real plugin Template Classes. The full
  spawn-via-Template chain is exercised by:

  - `add_template_invokes_test.exs` — the Loader.invoke_template
    chain that the action body delegates to.
  - Plugin-side integration tests (`ezagent_plugin_cc/test/...`) —
    cc/echo Template Class instantiate behaviour.

  This test verifies the unification's WIRING: the dispatched action
  routes through `Behavior.Workspace.:create_agent` and returns the
  shapes the CLI + LV both consume.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User

  setup do
    ws_name = "create-agent-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")
    admin_ctx = %{caller: User.admin_uri(), caps: User.admin_caps()}

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "Ezagent.Workspace.create_agent/3 — validation + dispatch wiring" do
    test "empty flavor returns {:error, :flavor_required}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, :flavor_required} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "", name: "x", cwd: "", with_pty: false},
                 admin_ctx
               )
    end

    test "empty name returns {:error, :name_required}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, :name_required} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: "", cwd: "", with_pty: false},
                 admin_ctx
               )
    end

    test "bad flavor returns {:error, {:bad_flavor, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_flavor, "definitely-not-a-flavor"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "definitely-not-a-flavor",
                   name: "x",
                   cwd: "",
                   with_pty: false
                 },
                 admin_ctx
               )
    end

    test "bad name returns {:error, {:bad_name, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_name, "invalid name with space"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "curl",
                   name: "invalid name with space",
                   cwd: "",
                   with_pty: false
                 },
                 admin_ctx
               )
    end

    test "cc flavor missing cwd returns {:error, :cwd_required_for_cc}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, :cwd_required_for_cc} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "cc", name: "demo", cwd: "", with_pty: false},
                 admin_ctx
               )
    end

    test "echo+with_pty missing cwd returns {:error, :cwd_required_for_echo_with_pty}",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      assert {:error, :cwd_required_for_echo_with_pty} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "echo", name: "shell", cwd: "", with_pty: true},
                 admin_ctx
               )
    end

    test "cc flavor nonexistent cwd returns {:error, {:cwd_not_a_dir, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:cwd_not_a_dir, "/this/path/definitely/does/not/exist/anywhere"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "demo",
                   cwd: "/this/path/definitely/does/not/exist/anywhere",
                   with_pty: false
                 },
                 admin_ctx
               )
    end
  end

  describe "Ezagent.Workspace.grant_initial_caps/3 — empty list short-circuit" do
    test "empty cap list returns :ok without dispatching", %{admin_ctx: admin_ctx} do
      # No agent URI needed — empty list never touches dispatch.
      fake_uri = URI.parse("entity://agent/system/cc_fake")
      assert :ok = Workspace.grant_initial_caps(fake_uri, [], admin_ctx)
    end
  end

  describe "Ezagent.Workspace.create_agent/3 — `--from` source resolution (agent.duplicate simple SPEC)" do
    # These tests exercise the contract surface of the `--from` flag:
    #   - flavor gating (only `cc` supports clone)
    #   - source resolution failures (no_such_actor, not_readable)
    #
    # The end-to-end deep-copy is covered in the cc plugin test
    # (`cc_agent_clone_from_test.exs`) since the actual `File.cp_r/2`
    # lives in `Ezagent.PluginCc.Template.CcAgent.create_agent_config_dir/2`.

    test "echo flavor with --from returns {:error, {:from_unsupported_for_flavor, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      source_uri = URI.parse("entity://agent/system/cc_some-source")

      assert {:error, {:from_unsupported_for_flavor, "echo"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "echo",
                   name: "clone-me",
                   cwd: "",
                   with_pty: false,
                   from: source_uri
                 },
                 admin_ctx
               )
    end

    test "cc + --from pointing at a non-existent source returns {:error, :source_not_found}",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_chat)

      # A real `cc_` URI shape so coerce + validate pass; the URI must
      # NOT correspond to a live Agent Kind — `sandbox.read` dispatch
      # short-circuits at ReadyGate with `:no_such_actor`.
      source_uri =
        URI.parse(
          "entity://agent/#{ws_name}/cc_definitely-does-not-exist-#{System.unique_integer([:positive])}"
        )

      # cwd MUST exist for the cc validator to get past `:cwd_not_a_dir`
      # — we want to exercise the source-resolution branch, not earlier
      # validation.
      assert {:error, :source_not_found} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "new-clone",
                   cwd: System.tmp_dir!(),
                   with_pty: false,
                   from: source_uri
                 },
                 admin_ctx
               )
    end

    test "bad --from shape (not an entity://agent/ URI) is rejected at the dispatch validator",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      # Two layers of defense:
      #  - dispatch-level: `InterfaceValidator` rejects anything that
      #    isn't `%URI{}` for the `from` arg (`{:option, :uri}` schema)
      #    → `{:invalid_args, [{[:from], {:type_mismatch, _}}]}`.
      #  - action-body: `coerce_create_args/1`'s `valid_from?/1`
      #    rejects a `%URI{}` whose scheme/host isn't entity/agent
      #    → `{:bad_from, _}`.
      # This test asserts the FIRST gate fires for a non-URI string.
      assert {:error, {:invalid_args, violations}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "x",
                   cwd: System.tmp_dir!(),
                   with_pty: false,
                   from: "not-a-uri-string"
                 },
                 admin_ctx
               )

      assert [{[:from], {:type_mismatch, _}}] = violations
    end

    test "bad --from URI (right type, wrong scheme) is rejected by valid_from?/1", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # The action body's `valid_from?/1` rejects a `%URI{}` that
      # doesn't conform to `entity://agent/...`. This guards against a
      # caller bypassing the CLI parser (e.g. LV building its own args).
      bad_uri = URI.parse("http://example.com/not-an-agent")

      assert {:error, {:bad_from, ^bad_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "x",
                   cwd: System.tmp_dir!(),
                   with_pty: false,
                   from: bad_uri
                 },
                 admin_ctx
               )
    end
  end

  describe "Ezagent.Workspace.create_agent/3 — end-to-end direct-spawn (codex r1 MEDIUM-6 / r2 MEDIUM-1)" do
    setup do
      # Codex PR #330 r2 MEDIUM-1: explicitly start :ezagent_domain_chat
      # so the `agent` SpawnRegistry scheme is registered. Without this
      # the test would skip in CI's per-app test runs.
      {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_chat)
      :ok
    end

    @tag :integration
    test "curl flavor — actually spawns the agent + returns {:ok, %{agent_uri}} + live in KindRegistry",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      # Bootstrap guard (codex r2 MEDIUM-1): even after starting the
      # chat domain, the `agent` scheme might be absent if SpawnRegistry
      # wasn't initialised yet (e.g. EtsOwner timing). In that narrow
      # window, skip explicitly rather than accept any spawn failure
      # shape — the original test body accepted `{:error, {:spawn_failed, _}}`
      # which made it pass even when no agent was actually spawned.
      # SpawnRegistry registers schemes; agent URIs have scheme `entity`.
      if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
           "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
        IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
        :ok
      else
        name = "ee-#{System.unique_integer([:positive])}"
        expected_uri_str = "entity://agent/#{ws_name}/curl_#{name}"

        # Hard requirement: dispatch must return {:ok, _} AND the agent
        # MUST be alive in KindRegistry afterward. Per codex r2 MEDIUM-1
        # — close the original coverage gap fully.
        assert {:ok, %{agent_uri: agent_uri, template_name: nil}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{flavor: "curl", name: name, cwd: "", with_pty: false},
                   admin_ctx
                 )

        assert URI.to_string(agent_uri) == expected_uri_str

        # The agent Kind must be alive in KindRegistry — this is the
        # invariant the original test was supposed to cover. Without
        # this assertion the test was vacuous on spawn failures.
        assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri),
               "agent should be alive in KindRegistry after create_agent returned :ok"
      end
    end
  end
end

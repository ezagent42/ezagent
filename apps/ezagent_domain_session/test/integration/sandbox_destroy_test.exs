defmodule EzagentDomainInstanceMessage.Integration.SandboxDestroyTest do
  @moduledoc """
  Integration test for `Ezagent.ActionSet.Sandbox` (PR2 2026-05-24, Allen)
  — exercises the full dispatch path against a real spawned Agent Kind.

  Asserts:

  - `sandbox.read` / `sandbox.update_config` resolve through `BehaviorRegistry`
    on the Agent Kind (registered in `register_chat_behaviors/0`);
  - A fresh Agent's `:sandbox` slice initializes to
    `%{config_dir_path: nil, template_class: nil}`;
  - `sandbox.update_config` dispatch persists the path + template_class;
  - `sandbox.destroy` schedules the agent's termination via the same
    detached-Task pattern as `Lifecycle.terminate`;
  - `destroy` invokes `template_class.destroy_config_dir/1` when the
    Template Class exports it (best-effort — failure is logged, not raised).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{BehaviorRegistry, KindRegistry}
  alias Ezagent.ActionSet.Sandbox
  alias Ezagent.Entity.{Agent, User}

  defp uniq, do: System.unique_integer([:positive])
  @workspace_uri URI.new!("workspace://team-alpha")

  defp spawn_agent_kind do
    uri = Ezagent.URI.new!("entity://team-alpha/agent/test_sandbox-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: uri})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, @workspace_uri)
    uri
  end

  defp dispatch(uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=sandbox.#{action}")
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until_gone(uri, tries \\ 50) do
    cond do
      tries == 0 ->
        :still_alive

      KindRegistry.lookup(uri) == :error ->
        :gone

      true ->
        Process.sleep(10)
        wait_until_gone(uri, tries - 1)
    end
  end

  describe "BehaviorRegistry resolution" do
    test "all 4 Sandbox actions resolve on the Agent Kind" do
      # B2' revoke-ordering fix (2026-08-04) added a 4th action,
      # `:wipe_git_identity` (the post-commit git-identity-wipe dispatch
      # target).
      for action <- [:read, :update_config, :destroy, :wipe_git_identity] do
        assert {:ok, Sandbox} = BehaviorRegistry.lookup(Agent, action),
               "Sandbox must register :#{action} on Agent Kind via register_chat_behaviors"
      end
    end

    test "Sandbox cap_subjects are CapabilityRegistry-known (the register path took them)" do
      # Smoke: the registration path raises if cap_subjects/0 is missing
      # any registered action — that the boot didn't crash is the
      # proof. This test just exists to flag the dependency.
      assert is_list(Sandbox.cap_subjects())
      assert length(Sandbox.cap_subjects()) == 4
    end
  end

  describe ":read on a freshly-spawned Agent" do
    test "the :sandbox slice initializes to all-nil for a default Agent.spawn" do
      uri = spawn_agent_kind()

      assert {:ok, %{config_dir_path: nil, template_class: nil}} =
               dispatch(uri, "read", %{})
    end
  end

  describe ":update_config persists the slice" do
    test "after update_config, :read returns the new fields" do
      uri = spawn_agent_kind()

      assert {:ok, %{config_dir_path: "/tmp/agent-x", template_class: StubClass}} =
               dispatch(uri, "update_config", %{
                 config_dir_path: "/tmp/agent-x",
                 template_class: StubClass
               })

      assert {:ok, %{config_dir_path: "/tmp/agent-x", template_class: StubClass}} =
               dispatch(uri, "read", %{})
    end

    test "update_config can be invoked multiple times (no immutability)" do
      uri = spawn_agent_kind()

      assert {:ok, _} =
               dispatch(uri, "update_config", %{
                 config_dir_path: "/tmp/v1",
                 template_class: ClassV1
               })

      assert {:ok, %{config_dir_path: "/tmp/v2", template_class: ClassV2}} =
               dispatch(uri, "update_config", %{
                 config_dir_path: "/tmp/v2",
                 template_class: ClassV2
               })

      assert {:ok, %{config_dir_path: "/tmp/v2", template_class: ClassV2}} =
               dispatch(uri, "read", %{})
    end
  end

  describe ":destroy brings the agent down" do
    test "destroy schedules termination — process is gone within ~50ms" do
      uri = spawn_agent_kind()
      assert {:ok, _pid} = KindRegistry.lookup(uri)

      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})

      assert :gone = wait_until_gone(uri),
             "the Agent process must be brought down after sandbox.destroy"
    end

    test "destroy with NO template_class is safe (skips FS cleanup)" do
      uri = spawn_agent_kind()
      assert {:ok, _pid} = KindRegistry.lookup(uri)

      # No update_config → template_class is nil → destroy should still work
      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})
      assert :gone = wait_until_gone(uri)
    end

    # 整支终审 K3 (codex 独有) — J1 补的两条 wipe 回归测试打的是 TemplateSpawn
    # rollback 与 RetirementSweeper（各自独立的 GitIdentityRuntime.wipe/1 调用
    # 点），不是这个 handle_destroy/2 ACTION 里 `sandbox.ex:426` 的那一行。日后
    # 那一行被删掉，前两条测试仍然全绿——这条才是钉住它的红演示。
    test "destroy wipes the agent's git-identity directory (no template_class needed)" do
      uri = spawn_agent_kind()
      git_identity_dir = Ezagent.Sandbox.GitIdentityDir.path(uri)
      File.mkdir_p!(git_identity_dir)
      File.write!(Path.join(git_identity_dir, "id_ed25519"), "fake-private-key")
      assert File.exists?(Path.join(git_identity_dir, "id_ed25519"))
      on_exit(fn -> File.rm_rf(git_identity_dir) end)

      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})

      refute File.exists?(git_identity_dir)
    end

    test "destroy invokes template_class.destroy_config_dir/2 with (agent_uri, config_dir)" do
      uri = spawn_agent_kind()
      config_dir = "/tmp/stubbed-#{uniq()}"

      # Wire a stub Template Class via update_config. The stub broadcasts
      # both args via PubSub so we can assert the callback was invoked
      # with the right tuple.
      assert {:ok, _} =
               dispatch(uri, "update_config", %{
                 config_dir_path: config_dir,
                 template_class: __MODULE__.StubTemplateClass
               })

      Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:sandbox_destroy:#{URI.to_string(uri)}")

      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})

      # Codex PR2 round-1 MEDIUM-3 — the callback gets BOTH (agent_uri,
      # config_dir_path); plugin doesn't reverse-engineer the path.
      assert_receive {:destroy_config_dir_called, ^uri, ^config_dir}, 1_000

      assert :gone = wait_until_gone(uri)
    end
  end

  describe "destroy gate (codex PR2 round-1 HIGH-2)" do
    # The detached-Task pattern in Lifecycle / Sandbox does Process.sleep(20)
    # before terminating, so the dispatch immediately after destroy()
    # lands within the live window. We assert STRICTLY on :destroyed —
    # accepting :no_such_actor would mask a regression where the gate
    # clause never fires (codex round-2 MEDIUM-2).

    test "after :destroy, :read STRICTLY returns {:error, :destroyed}" do
      uri = spawn_agent_kind()

      assert {:ok, _} =
               dispatch(uri, "update_config", %{config_dir_path: "/tmp/x", template_class: nil})

      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})

      assert {:error, :destroyed} = dispatch(uri, "read", %{}),
             "post-destroy read must hit the gate clause (not :no_such_actor)"

      assert :gone = wait_until_gone(uri)
    end

    test "after :destroy, :update_config STRICTLY returns {:error, :destroyed}" do
      uri = spawn_agent_kind()

      assert {:ok, _} =
               dispatch(uri, "update_config", %{config_dir_path: "/tmp/x", template_class: nil})

      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})

      assert {:error, :destroyed} =
               dispatch(uri, "update_config", %{config_dir_path: "/tmp/y", template_class: nil}),
             "post-destroy update_config must hit the gate clause (not :no_such_actor)"

      assert :gone = wait_until_gone(uri)
    end
  end

  describe "re-spawn after destroy (codex PR2 round-2 HIGH-2 + round-3 HIGH-1)" do
    test "re-spawning the same agent URI after destroy starts with a CLEAN slice (no stale config_dir_path)" do
      # Two regressions covered here:
      # 1. (Round-2 HIGH-2) Snapshot persistence of destroyed?: true
      #    would permanently gate re-spawned agents. Fix moved the gate
      #    to process dict.
      # 2. (Round-3 HIGH-1) The slice itself (config_dir_path +
      #    template_class) was previously persisted unchanged through
      #    destroy → re-spawn would rehydrate config_dir_path pointing
      #    at a deleted dir. Fix: :destroy returns a CLEARED slice so
      #    the :on_terminate snapshot saves empty state.
      uri = spawn_agent_kind()

      assert {:ok, _} =
               dispatch(uri, "update_config", %{
                 config_dir_path: "/tmp/v1",
                 template_class: nil
               })

      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})
      assert :gone = wait_until_gone(uri)

      # Re-spawn the SAME URI.
      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: uri})
      :ok = Ezagent.WorkspaceRegistry.bind(uri, @workspace_uri)

      # Round-2 regression — the fresh process must NOT carry the
      # destroyed gate. Read succeeds.
      # Round-3 regression — the read must return NIL fields, not the
      # stale "/tmp/v1" the destroyed agent had.
      assert {:ok, %{config_dir_path: nil, template_class: nil}} =
               dispatch(uri, "read", %{}),
             "re-spawned agent must inherit a CLEARED slice (no stale config_dir_path)"

      # And update_config can now populate fresh state.
      assert {:ok, %{config_dir_path: "/tmp/v2"}} =
               dispatch(uri, "update_config", %{
                 config_dir_path: "/tmp/v2",
                 template_class: nil
               })

      assert {:ok, %{config_dir_path: "/tmp/v2"}} = dispatch(uri, "read", %{})
    end
  end

  describe "destroy_config_dir/2 robustness (codex PR2 round-2 HIGH-1)" do
    test "a RAISING destroy_config_dir does NOT block termination" do
      uri = spawn_agent_kind()

      assert {:ok, _} =
               dispatch(uri, "update_config", %{
                 config_dir_path: "/tmp/raises",
                 template_class: __MODULE__.RaisingStubClass
               })

      # The raising stub raises a RuntimeError. The destroy action MUST
      # rescue it, log + continue scheduling termination.
      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})

      assert :gone = wait_until_gone(uri),
             "Agent process must terminate even when destroy_config_dir raises"
    end

    test "a callback that EXITS does NOT block termination" do
      uri = spawn_agent_kind()

      assert {:ok, _} =
               dispatch(uri, "update_config", %{
                 config_dir_path: "/tmp/exits",
                 template_class: __MODULE__.ExitingStubClass
               })

      assert {:ok, %{destroyed: true}} = dispatch(uri, "destroy", %{})
      assert :gone = wait_until_gone(uri)
    end
  end

  describe "destroy with FAILED cleanup preserves slice (codex PR2 round-4 HIGH-2)" do
    test "raised cleanup → slice config_dir_path SURVIVES into the snapshot (ops can retry)" do
      # Round-4 fix: on cleanup failure, slice is NOT cleared — the path
      # + template_class survive into the :on_terminate snapshot so
      # admin/ops can see "this agent destroyed but cleanup failed at
      # this path" and retry out-of-band. Pre-fix the slice was
      # unconditionally cleared, losing the only recoverable pointer to
      # leaked filesystem state.
      uri = spawn_agent_kind()
      config_dir = "/tmp/cleanup-fails-#{uniq()}"

      assert {:ok, _} =
               dispatch(uri, "update_config", %{
                 config_dir_path: config_dir,
                 template_class: __MODULE__.RaisingStubClass
               })

      # The destroy action result carries the cleanup status now.
      assert {:ok, %{destroyed: true, cleanup: {:error, _}}} =
               dispatch(uri, "destroy", %{})

      # Wait for termination. The :on_terminate snapshot fires and
      # saves the PRESERVED slice.
      assert :gone = wait_until_gone(uri)

      # Re-spawn the same URI and read the slice. It must still carry
      # the original config_dir_path + template_class (NOT nil).
      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: uri})
      :ok = Ezagent.WorkspaceRegistry.bind(uri, @workspace_uri)

      expected_class = __MODULE__.RaisingStubClass

      assert {:ok, %{config_dir_path: ^config_dir, template_class: ^expected_class}} =
               dispatch(uri, "read", %{}),
             "after a failed cleanup the slice MUST be preserved across re-spawn so ops can retry"
    end

    test "successful cleanup → slice IS cleared (the success path stays as designed)" do
      uri = spawn_agent_kind()
      config_dir = "/tmp/cleanup-succeeds-#{uniq()}"

      assert {:ok, _} =
               dispatch(uri, "update_config", %{
                 config_dir_path: config_dir,
                 template_class: __MODULE__.StubTemplateClass
               })

      # Stub returns :ok → cleanup succeeded.
      assert {:ok, %{destroyed: true, cleanup: :ok}} = dispatch(uri, "destroy", %{})
      assert :gone = wait_until_gone(uri)

      # Re-spawn — slice is CLEARED.
      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: uri})
      :ok = Ezagent.WorkspaceRegistry.bind(uri, @workspace_uri)

      assert {:ok, %{config_dir_path: nil, template_class: nil}} =
               dispatch(uri, "read", %{}),
             "after a successful cleanup the slice MUST be cleared"
    end
  end

  # Stub Template Class — implements only the destroy_config_dir/2
  # callback so we can observe its invocation. NOT a full Template Class
  # (no template_name / validate / instantiate); Sandbox.destroy only
  # consults `function_exported?/3` against destroy_config_dir.
  #
  # Codex PR2 round-1 MEDIUM-3 — arity is /2, gets (agent_uri, config_dir_path).
  defmodule StubTemplateClass do
    def destroy_config_dir(%URI{} = agent_uri, config_dir) when is_binary(config_dir) do
      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        "test:sandbox_destroy:#{URI.to_string(agent_uri)}",
        {:destroy_config_dir_called, agent_uri, config_dir}
      )

      :ok
    end
  end

  # Codex PR2 round-2 HIGH-1 — destroy_config_dir/2 might RAISE or EXIT
  # (FS errors, plugin bugs). The destroy action must rescue + continue
  # so termination still happens.
  defmodule RaisingStubClass do
    def destroy_config_dir(%URI{} = _agent_uri, _config_dir) do
      raise RuntimeError, "simulated plugin filesystem error"
    end
  end

  defmodule ExitingStubClass do
    def destroy_config_dir(%URI{} = _agent_uri, _config_dir) do
      exit(:simulated_exit)
    end
  end
end

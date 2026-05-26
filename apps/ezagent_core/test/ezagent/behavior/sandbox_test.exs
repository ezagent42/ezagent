defmodule Ezagent.Behavior.SandboxTest do
  @moduledoc """
  Contract test for `Ezagent.Behavior.Sandbox` (PR2 2026-05-24, Allen) —
  per-agent config_dir + extension-management scaffolding.

  Pure-function level: `actions/0`, `state_slice/0`, `init_slice/1`,
  `invoke/4` for `:read` / `:write_path`. The `:destroy` action is
  exercised in the integration test (it has side effects on the OTP
  supervision tree).
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Sandbox

  describe "Behavior contract surface" do
    test "actions/0 returns [:read, :write_path, :destroy]" do
      assert Sandbox.actions() == [:read, :write_path, :destroy]
    end

    test "state_slice/0 is :sandbox" do
      assert Sandbox.state_slice() == :sandbox
    end

    test "init_slice/1 defaults all fields to nil for an unconfigured agent" do
      assert Sandbox.init_slice(%{uri: URI.new!("entity://agent/team-alpha/x")}) ==
               %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}
    end

    test "init_slice/1 reads config_dir_path + template_class + respawn_template_data from args" do
      args = %{
        config_dir_path: "/tmp/agent-x",
        template_class: SomeMod,
        respawn_template_data: %{"cwd" => "/tmp/agent-x"}
      }

      assert Sandbox.init_slice(args) ==
               %{
                 config_dir_path: "/tmp/agent-x",
                 template_class: SomeMod,
                 respawn_template_data: %{"cwd" => "/tmp/agent-x"}
               }
    end

    test "init_slice/1 omits respawn_template_data when absent from args" do
      args = %{config_dir_path: "/tmp/agent-x", template_class: SomeMod}

      # Missing key → nil in the slice (the PTY-orphan-restart respawn
      # flow opts in via :write_path, not via init_slice; legacy spawn
      # paths that don't dispatch the new key still produce a clean slice).
      assert Sandbox.init_slice(args) ==
               %{
                 config_dir_path: "/tmp/agent-x",
                 template_class: SomeMod,
                 respawn_template_data: nil
               }
    end

    test "init_slice/1 RESETS the process-dict destroyed gate (codex PR2 round-2 HIGH-2)" do
      # A prior incarnation in the SAME OS process could have left
      # the gate set. init_slice MUST clear it so a re-spawn at the
      # same URI is not silently locked out.
      Process.put({Sandbox, :destroyed?}, true)

      _ = Sandbox.init_slice(%{})

      refute Process.get({Sandbox, :destroyed?}),
             "init_slice must clear the destroyed gate"
    end

    test "cap_subjects/0 carries all 3 subjects" do
      subjects = Sandbox.cap_subjects() |> Enum.map(&elem(&1, 0))
      assert subjects == [:read, :write_path, :destroy]
    end

    test "interface/0 declares all 3 actions, all :call mode" do
      iface = Sandbox.interface()
      assert Map.keys(iface) |> Enum.sort() == [:destroy, :read, :write_path]
      for {_action, def} <- iface, do: assert(def.modes == [:call])
    end
  end

  describe "invoke(:read, ...)" do
    setup do
      # Process-dict gate isolation — each test starts with the gate
      # absent (the test process has never been "destroyed").
      Process.delete({Sandbox, :destroyed?})
      :ok
    end

    test "returns the slice fields" do
      slice = %{
        config_dir_path: "/tmp/cd",
        template_class: SomeMod,
        respawn_template_data: %{"cwd" => "/tmp/cd"}
      }

      assert {:ok, ^slice,
              %{
                config_dir_path: "/tmp/cd",
                template_class: SomeMod,
                respawn_template_data: %{"cwd" => "/tmp/cd"}
              }} =
               Sandbox.invoke(:read, slice, %{}, %{})
    end

    test "returns nils for an unpopulated slice" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:ok, ^slice,
              %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}} =
               Sandbox.invoke(:read, slice, %{}, %{})
    end

    test "REJECTS once the process-dict gate is set (codex PR2 round-1 HIGH-2)" do
      Process.put({Sandbox, :destroyed?}, true)
      slice = %{config_dir_path: "/tmp/x", template_class: SomeMod, respawn_template_data: nil}

      assert {:error, :destroyed} = Sandbox.invoke(:read, slice, %{}, %{})
    end
  end

  describe "invoke(:write_path, ...)" do
    setup do
      Process.delete({Sandbox, :destroyed?})
      :ok
    end

    test "sets both fields in the slice (legacy 2-key write, leaves respawn_template_data alone)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}
      args = %{config_dir_path: "/tmp/agent-y", template_class: MyClass}

      assert {:ok, new_slice,
              %{
                config_dir_path: "/tmp/agent-y",
                template_class: MyClass,
                respawn_template_data: nil
              }} =
               Sandbox.invoke(:write_path, slice, args, %{})

      # Legacy 2-key write — respawn_template_data is NOT touched.
      assert new_slice == %{
               config_dir_path: "/tmp/agent-y",
               template_class: MyClass,
               respawn_template_data: nil
             }
    end

    test "sets respawn_template_data when supplied (PTY-orphan-restart 2026-05-26)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      args = %{
        config_dir_path: "/tmp/agent-z",
        template_class: MyClass,
        respawn_template_data: %{"cwd" => "/tmp/agent-z", "extra" => "k"}
      }

      assert {:ok, new_slice,
              %{
                config_dir_path: "/tmp/agent-z",
                template_class: MyClass,
                respawn_template_data: %{"cwd" => "/tmp/agent-z", "extra" => "k"}
              }} =
               Sandbox.invoke(:write_path, slice, args, %{})

      assert new_slice == %{
               config_dir_path: "/tmp/agent-z",
               template_class: MyClass,
               respawn_template_data: %{"cwd" => "/tmp/agent-z", "extra" => "k"}
             }
    end

    test "overwrites previously-set fields (no immutability semantics)" do
      slice = %{
        config_dir_path: "/old/path",
        template_class: OldClass,
        respawn_template_data: %{"cwd" => "/old/path"}
      }

      args = %{
        config_dir_path: "/new/path",
        template_class: NewClass,
        respawn_template_data: %{"cwd" => "/new/path"}
      }

      assert {:ok, new_slice,
              %{
                config_dir_path: "/new/path",
                template_class: NewClass,
                respawn_template_data: %{"cwd" => "/new/path"}
              }} =
               Sandbox.invoke(:write_path, slice, args, %{})

      assert new_slice == %{
               config_dir_path: "/new/path",
               template_class: NewClass,
               respawn_template_data: %{"cwd" => "/new/path"}
             }
    end

    test "rejects an invalid config_dir_path type (non-string, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:error, {:invalid_config_dir_path, 123}} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{config_dir_path: 123, template_class: nil},
                 %{}
               )
    end

    test "rejects an invalid template_class type (non-atom, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:error, {:invalid_template_class, "ModString"}} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{config_dir_path: nil, template_class: "ModString"},
                 %{}
               )
    end

    test "rejects an invalid respawn_template_data type (non-map, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:error, {:invalid_respawn_template_data, "not-a-map"}} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{
                   config_dir_path: nil,
                   template_class: nil,
                   respawn_template_data: "not-a-map"
                 },
                 %{}
               )
    end

    test "accepts nil for all three (clearing the slice)" do
      slice = %{
        config_dir_path: "/old",
        template_class: OldClass,
        respawn_template_data: %{"cwd" => "/old"}
      }

      assert {:ok, new_slice,
              %{
                config_dir_path: nil,
                template_class: nil,
                respawn_template_data: nil
              }} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{config_dir_path: nil, template_class: nil, respawn_template_data: nil},
                 %{}
               )

      assert new_slice == %{
               config_dir_path: nil,
               template_class: nil,
               respawn_template_data: nil
             }
    end

    test "REJECTS once the process-dict gate is set (codex PR2 round-1 HIGH-2)" do
      Process.put({Sandbox, :destroyed?}, true)
      slice = %{config_dir_path: "/tmp/x", template_class: SomeMod, respawn_template_data: nil}

      assert {:error, :destroyed} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{config_dir_path: "/new", template_class: NewMod},
                 %{}
               )
    end
  end

  describe "post_init/2 + handle_continue/3 (PTY-orphan-restart 2026-05-26)" do
    setup do
      Process.delete({Sandbox, :destroyed?})
      :ok
    end

    test "post_init/2 returns :ok when slice has no template_class" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}
      assert Sandbox.post_init(%{}, slice) == :ok
    end

    test "post_init/2 returns :ok when slice has template_class but no respawn_template_data" do
      slice = %{
        config_dir_path: "/tmp/x",
        template_class: SomeMod,
        respawn_template_data: nil
      }

      assert Sandbox.post_init(%{}, slice) == :ok
    end

    test "post_init/2 returns {:continue, ...} when both template_class + respawn_template_data are present" do
      slice = %{
        config_dir_path: "/tmp/x",
        template_class: SomeMod,
        respawn_template_data: %{"cwd" => "/tmp/x"}
      }

      assert {:continue, {:ensure_subprocess, SomeMod, %{"cwd" => "/tmp/x"}}} =
               Sandbox.post_init(%{}, slice)
    end

    test "handle_continue/3 :ignores when template_class does not export ensure_subprocess_alive/2" do
      # `Enum` is a stdlib module that does not export the callback —
      # the probe path is exercised without needing a mock module.
      slice = %{config_dir_path: nil, template_class: Enum, respawn_template_data: %{}}
      ctx = %{self_uri: URI.new!("entity://agent/system/cc_x"), kind_module: SomeKind}

      assert :ignore =
               Sandbox.handle_continue({:ensure_subprocess, Enum, %{}}, slice, ctx)
    end

    test "handle_continue/3 :ignores when template_class is not an atom" do
      slice = %{config_dir_path: nil, template_class: "not-atom", respawn_template_data: %{}}
      ctx = %{self_uri: URI.new!("entity://agent/system/cc_x"), kind_module: SomeKind}

      assert :ignore =
               Sandbox.handle_continue({:ensure_subprocess, "not-atom", %{}}, slice, ctx)
    end
  end
end

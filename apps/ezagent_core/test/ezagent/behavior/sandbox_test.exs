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

    test "init_slice/1 defaults both fields to nil for an unconfigured agent" do
      assert Sandbox.init_slice(%{uri: URI.new!("entity://agent/default/x")}) ==
               %{config_dir_path: nil, template_class: nil}
    end

    test "init_slice/1 reads config_dir_path + template_class from args" do
      args = %{config_dir_path: "/tmp/agent-x", template_class: SomeMod}

      assert Sandbox.init_slice(args) ==
               %{config_dir_path: "/tmp/agent-x", template_class: SomeMod}
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
      slice = %{config_dir_path: "/tmp/cd", template_class: SomeMod}

      assert {:ok, ^slice, %{config_dir_path: "/tmp/cd", template_class: SomeMod}} =
               Sandbox.invoke(:read, slice, %{}, %{})
    end

    test "returns nils for an unpopulated slice" do
      slice = %{config_dir_path: nil, template_class: nil}

      assert {:ok, ^slice, %{config_dir_path: nil, template_class: nil}} =
               Sandbox.invoke(:read, slice, %{}, %{})
    end

    test "REJECTS once the process-dict gate is set (codex PR2 round-1 HIGH-2)" do
      Process.put({Sandbox, :destroyed?}, true)
      slice = %{config_dir_path: "/tmp/x", template_class: SomeMod}

      assert {:error, :destroyed} = Sandbox.invoke(:read, slice, %{}, %{})
    end
  end

  describe "invoke(:write_path, ...)" do
    setup do
      Process.delete({Sandbox, :destroyed?})
      :ok
    end

    test "sets both fields in the slice" do
      slice = %{config_dir_path: nil, template_class: nil}
      args = %{config_dir_path: "/tmp/agent-y", template_class: MyClass}

      assert {:ok, new_slice, %{config_dir_path: "/tmp/agent-y", template_class: MyClass}} =
               Sandbox.invoke(:write_path, slice, args, %{})

      assert new_slice == %{config_dir_path: "/tmp/agent-y", template_class: MyClass}
    end

    test "overwrites previously-set fields (no immutability semantics)" do
      slice = %{config_dir_path: "/old/path", template_class: OldClass}
      args = %{config_dir_path: "/new/path", template_class: NewClass}

      assert {:ok, new_slice, %{config_dir_path: "/new/path", template_class: NewClass}} =
               Sandbox.invoke(:write_path, slice, args, %{})

      assert new_slice == %{config_dir_path: "/new/path", template_class: NewClass}
    end

    test "rejects an invalid config_dir_path type (non-string, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil}

      assert {:error, {:invalid_config_dir_path, 123}} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{config_dir_path: 123, template_class: nil},
                 %{}
               )
    end

    test "rejects an invalid template_class type (non-atom, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil}

      assert {:error, {:invalid_template_class, "ModString"}} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{config_dir_path: nil, template_class: "ModString"},
                 %{}
               )
    end

    test "accepts nil for both (clearing the slice)" do
      slice = %{config_dir_path: "/old", template_class: OldClass}

      assert {:ok, new_slice, %{config_dir_path: nil, template_class: nil}} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{config_dir_path: nil, template_class: nil},
                 %{}
               )

      assert new_slice == %{config_dir_path: nil, template_class: nil}
    end

    test "REJECTS once the process-dict gate is set (codex PR2 round-1 HIGH-2)" do
      Process.put({Sandbox, :destroyed?}, true)
      slice = %{config_dir_path: "/tmp/x", template_class: SomeMod}

      assert {:error, :destroyed} =
               Sandbox.invoke(
                 :write_path,
                 slice,
                 %{config_dir_path: "/new", template_class: NewMod},
                 %{}
               )
    end
  end
end

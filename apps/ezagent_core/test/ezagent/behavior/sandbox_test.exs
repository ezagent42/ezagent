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

  # ---------------------------------------------------------------
  # Legacy-shape adapter (Phase 2.5 migration helper)
  #
  # The pre-migration tests called `invoke_via_new_contract(action, slice, args,
  # ctx)` and asserted on the resulting `{:ok, new_slice, result}` /
  # `{:error, reason}` shape. The new contract dispatches via
  # `handle_<action>/2` + `{:set, key, value}` effects.
  #
  # `invoke_via_new_contract/4` provides the legacy shape on top of
  # the new contract: it injects `ctx[:read]/2` to expose the slice
  # to the handler, runs `apply_effects/2` against the slice to
  # produce the new slice, and lifts the result back into the
  # 3-tuple the legacy tests assert on. This keeps the SEMANTIC
  # coverage of the existing tests intact (they catch any regression
  # in the read/write/validate logic) while validating the new
  # contract's effect application at the same time.
  # ---------------------------------------------------------------
  defp invoke_via_new_contract(action, slice, args, ctx) do
    handler = String.to_atom("handle_#{action}")
    read = fn key, default -> Map.get(slice, key, default) end
    ctx_with_read = Map.put(ctx, :read, read)

    case apply(Sandbox, handler, [args, ctx_with_read]) do
      {:ok, result, effects} when is_list(effects) ->
        {:ok, %{state: new_slice}} = Ezagent.Behavior.apply_effects(effects, slice)
        {:ok, new_slice, result}

      {:error, _} = err ->
        err
    end
  end

  describe "Behavior contract surface" do
    test "actions/0 returns [:read, :write_path, :destroy]" do
      assert Sandbox.actions() == [:read, :write_path, :destroy]
    end

    test "state_slice/0 is :sandbox" do
      assert Sandbox.state_slice() == :sandbox
    end

    test "init_slice/1 defaults all fields to nil for an unconfigured agent" do
      assert Sandbox.init_slice(%{uri: URI.new!("entity://agent/team-alpha/x")}) ==
               %{
                 config_dir_path: nil,
                 template_class: nil,
                 respawn_template_data: nil,
                 # PTY-phase-state-machine 2026-05-26 follow-up (b)
                 pty_phase: nil
               }
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
                 respawn_template_data: %{"cwd" => "/tmp/agent-x"},
                 pty_phase: nil
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
                 respawn_template_data: nil,
                 pty_phase: nil
               }
    end

    test "init_slice/1 accepts pty_phase from rehydrated snapshot" do
      # PTY-phase-state-machine 2026-05-26 follow-up (b): when the
      # Kind.Server loads from snapshot, the slice arrives carrying
      # the persisted phase. init_slice/1 passes it through.
      args = %{pty_phase: :running}

      slice = Sandbox.init_slice(args)
      assert slice.pty_phase == :running
    end

    test "init_slice/1 normalizes invalid pty_phase values to nil" do
      # Defensive: a corrupt snapshot or buggy caller supplies a
      # non-atom or unknown atom — reset to nil so the next live
      # broadcast (or post_init re-spawn) writes the correct value.
      assert Sandbox.init_slice(%{pty_phase: :totally_bogus}).pty_phase == nil
      assert Sandbox.init_slice(%{pty_phase: "starting"}).pty_phase == nil
      assert Sandbox.init_slice(%{pty_phase: 42}).pty_phase == nil
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
        respawn_template_data: %{"cwd" => "/tmp/cd"},
        pty_phase: :running
      }

      assert {:ok, ^slice,
              %{
                config_dir_path: "/tmp/cd",
                template_class: SomeMod,
                respawn_template_data: %{"cwd" => "/tmp/cd"},
                pty_phase: :running
              }} =
               invoke_via_new_contract(:read, slice, %{}, %{})
    end

    test "returns nils for an unpopulated slice" do
      slice = %{
        config_dir_path: nil,
        template_class: nil,
        respawn_template_data: nil,
        pty_phase: nil
      }

      assert {:ok, ^slice,
              %{
                config_dir_path: nil,
                template_class: nil,
                respawn_template_data: nil,
                pty_phase: nil
              }} =
               invoke_via_new_contract(:read, slice, %{}, %{})
    end

    test "REJECTS once the process-dict gate is set (codex PR2 round-1 HIGH-2)" do
      Process.put({Sandbox, :destroyed?}, true)
      slice = %{config_dir_path: "/tmp/x", template_class: SomeMod, respawn_template_data: nil}

      assert {:error, :destroyed} = invoke_via_new_contract(:read, slice, %{}, %{})
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
               invoke_via_new_contract(:write_path, slice, args, %{})

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
               invoke_via_new_contract(:write_path, slice, args, %{})

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
               invoke_via_new_contract(:write_path, slice, args, %{})

      assert new_slice == %{
               config_dir_path: "/new/path",
               template_class: NewClass,
               respawn_template_data: %{"cwd" => "/new/path"}
             }
    end

    test "rejects an invalid config_dir_path type (non-string, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:error, {:invalid_config_dir_path, 123}} =
               invoke_via_new_contract(
                 :write_path,
                 slice,
                 %{config_dir_path: 123, template_class: nil},
                 %{}
               )
    end

    test "rejects an invalid template_class type (non-atom, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:error, {:invalid_template_class, "ModString"}} =
               invoke_via_new_contract(
                 :write_path,
                 slice,
                 %{config_dir_path: nil, template_class: "ModString"},
                 %{}
               )
    end

    test "rejects an invalid respawn_template_data type (non-map, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:error, {:invalid_respawn_template_data, "not-a-map"}} =
               invoke_via_new_contract(
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
               invoke_via_new_contract(
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
               invoke_via_new_contract(
                 :write_path,
                 slice,
                 %{config_dir_path: "/new", template_class: NewMod},
                 %{}
               )
    end
  end

  describe "post_init/2 + handle_continue/3 (PTY-orphan-restart 2026-05-26 + phase-state-machine follow-up b)" do
    setup do
      Process.delete({Sandbox, :destroyed?})
      :ok
    end

    test "post_init/2 ALWAYS returns {:continue, :setup_phase_tracking, ...} (follow-up b)" do
      # PTY-phase-state-machine follow-up (b): post_init now
      # unconditionally schedules the subscribe+ensure continuation
      # so the Kind.Server subscribes to `pty:phase:<self_uri>` for
      # every Sandbox-bearing agent (fresh-spawn, restart, demand-spawn).
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:continue, {:setup_phase_tracking, nil, nil}} =
               Sandbox.post_init(%{}, slice)
    end

    test "post_init/2 carries template_class + respawn_data into the continuation" do
      slice = %{
        config_dir_path: "/tmp/x",
        template_class: SomeMod,
        respawn_template_data: %{"cwd" => "/tmp/x"}
      }

      assert {:continue, {:setup_phase_tracking, SomeMod, %{"cwd" => "/tmp/x"}}} =
               Sandbox.post_init(%{}, slice)
    end

    test "handle_continue/3 :ignores when template_class is nil (subscribe-only path)" do
      # PTY-phase-state-machine follow-up (b): nil template_class
      # means "subscribe-only" — phase tracking is set up but no
      # subprocess re-spawn is attempted.
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}
      ctx = %{self_uri: URI.new!("entity://agent/system/cc_x"), kind_module: SomeKind}

      assert :ignore =
               Sandbox.handle_continue({:setup_phase_tracking, nil, nil}, slice, ctx)
    end

    test "handle_continue/3 :ignores when template_class does not export ensure_subprocess_alive/2" do
      # `Enum` is a stdlib module that does not export the callback —
      # the probe path is exercised without needing a mock module.
      slice = %{config_dir_path: nil, template_class: Enum, respawn_template_data: %{}}
      ctx = %{self_uri: URI.new!("entity://agent/system/cc_x"), kind_module: SomeKind}

      assert :ignore =
               Sandbox.handle_continue({:setup_phase_tracking, Enum, %{}}, slice, ctx)
    end

    test "handle_continue/3 :ignores when template_class is not an atom" do
      slice = %{config_dir_path: nil, template_class: "not-atom", respawn_template_data: %{}}
      ctx = %{self_uri: URI.new!("entity://agent/system/cc_x"), kind_module: SomeKind}

      assert :ignore =
               Sandbox.handle_continue({:setup_phase_tracking, "not-atom", %{}}, slice, ctx)
    end
  end

  describe "handle_kind_message/3 (PTY-phase-state-machine 2026-05-26 follow-up b)" do
    test "writes a :pty_phase event into the slice" do
      slice = %{
        config_dir_path: "/tmp/x",
        template_class: SomeMod,
        respawn_template_data: nil,
        pty_phase: :starting
      }

      agent_uri = URI.new!("entity://agent/system/cc_x")
      ctx = %{self_uri: agent_uri, kind_module: SomeKind}

      meta = %{os_pid: 12_345, reason: nil, at: 1_700_000_000_000}

      assert {:ok, new_slice} =
               Sandbox.handle_kind_message(
                 {:pty_phase, agent_uri, :running, meta},
                 slice,
                 ctx
               )

      assert new_slice.pty_phase == :running
      # Other fields preserved
      assert new_slice.config_dir_path == "/tmp/x"
      assert new_slice.template_class == SomeMod
    end

    test "ignores non-phase messages" do
      slice = %{pty_phase: :running}
      ctx = %{self_uri: URI.new!("entity://agent/system/cc_x")}

      assert :ignore = Sandbox.handle_kind_message(:something_else, slice, ctx)
      assert :ignore = Sandbox.handle_kind_message({:not_a_phase, :foo}, slice, ctx)
    end

    test "ignores phase events with invalid phase atoms (defensive)" do
      slice = %{pty_phase: :running}
      agent_uri = URI.new!("entity://agent/system/cc_x")
      ctx = %{self_uri: agent_uri}

      assert :ignore =
               Sandbox.handle_kind_message(
                 {:pty_phase, agent_uri, :bogus, %{}},
                 slice,
                 ctx
               )
    end

    test "ignores phase events whose agent_uri ≠ ctx.self_uri (codex MED-2 topic-collision defense)" do
      # PubSub topics are not an authentication boundary; a stray
      # publisher or topic collision could deliver a `{:pty_phase, X, ...}`
      # to a Kind whose self_uri is Y. Verify identity BEFORE
      # mutating the slice.
      slice = %{pty_phase: :running}
      self_uri = URI.new!("entity://agent/system/cc_self")
      foreign_uri = URI.new!("entity://agent/system/cc_other")
      ctx = %{self_uri: self_uri}

      assert :ignore =
               Sandbox.handle_kind_message(
                 {:pty_phase, foreign_uri, :dead, %{}},
                 slice,
                 ctx
               )
    end
  end
end

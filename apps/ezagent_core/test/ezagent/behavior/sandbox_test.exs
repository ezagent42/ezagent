defmodule Ezagent.ActionSet.SandboxTest do
  @moduledoc """
  Contract test for `Ezagent.ActionSet.Sandbox` (PR2 2026-05-24, Allen) —
  per-agent config_dir + extension-management scaffolding.

  Pure-function level: `actions/0`, `state_slice/0`, `init_slice/1`,
  `invoke/4` for `:read` / `:update_config`. The `:destroy` action is
  exercised in the integration test (it has side effects on the OTP
  supervision tree).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Sandbox

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
        {:ok, %{state: new_slice}} = Ezagent.ActionSet.apply_effects(effects, slice)
        {:ok, new_slice, result}

      {:error, _} = err ->
        err
    end
  end

  describe "Behavior contract surface" do
    test "actions/0 returns [:read, :update_config, :destroy]" do
      assert Sandbox.actions() == [:read, :update_config, :destroy]
    end

    test "state_slice/0 is :sandbox" do
      assert Sandbox.state_slice() == :sandbox
    end

    test "init_slice/1 defaults all state fields to nil for an unconfigured agent" do
      # Lifecycle two-container shape (SPEC §2.1): durable fields under
      # `:state`, `:transients` empty (activate/2 fills it).
      assert Sandbox.init_slice(%{uri: URI.new!("entity://team-alpha/agent/x")}) ==
               %{
                 state: %{
                   config_dir_path: nil,
                   template_class: nil,
                   respawn_template_data: nil,
                   # PTY-phase-state-machine 2026-05-26 follow-up (b)
                   pty_phase: nil,
                   # RF-5a/RF-6 durable passive marker — false (principal) default.
                   passive: false,
                   # P2 durable recipe-provenance — nil (no recipe) default.
                   recipe: nil
                 },
                 transients: %{}
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
                 state: %{
                   config_dir_path: "/tmp/agent-x",
                   template_class: SomeMod,
                   respawn_template_data: %{"cwd" => "/tmp/agent-x"},
                   pty_phase: nil,
                   passive: false,
                   recipe: nil
                 },
                 transients: %{}
               }
    end

    test "init_slice/1 omits respawn_template_data when absent from args" do
      args = %{config_dir_path: "/tmp/agent-x", template_class: SomeMod}

      # Missing key → nil in state (the PTY-orphan-restart respawn flow
      # opts in via :update_config, not via create/1; legacy spawn paths
      # that don't dispatch the new key still produce a clean state).
      assert Sandbox.init_slice(args) ==
               %{
                 state: %{
                   config_dir_path: "/tmp/agent-x",
                   template_class: SomeMod,
                   respawn_template_data: nil,
                   pty_phase: nil,
                   passive: false,
                   recipe: nil
                 },
                 transients: %{}
               }
    end

    test "create/1 accepts pty_phase from rehydrated snapshot" do
      # PTY-phase-state-machine 2026-05-26 follow-up (b): create/1 passes
      # a valid persisted phase through.
      assert {:ok, state} = Sandbox.create(%{pty_phase: :running})
      assert state.pty_phase == :running
    end

    test "create/1 normalizes invalid pty_phase values to nil" do
      # Defensive: a corrupt snapshot or buggy caller supplies a non-atom
      # or unknown atom — reset to nil so the next live broadcast (or the
      # activate re-spawn flow) writes the correct value.
      assert {:ok, %{pty_phase: nil}} = Sandbox.create(%{pty_phase: :totally_bogus})
      assert {:ok, %{pty_phase: nil}} = Sandbox.create(%{pty_phase: "starting"})
      assert {:ok, %{pty_phase: nil}} = Sandbox.create(%{pty_phase: 42})
    end

    test "cap_subjects/0 carries all 3 subjects" do
      subjects = Sandbox.cap_subjects() |> Enum.map(&elem(&1, 0))
      assert subjects == [:read, :update_config, :destroy]
    end

    test "interface/0 declares all 3 actions, all :call mode" do
      iface = Sandbox.interface()
      assert Map.keys(iface) |> Enum.sort() == [:destroy, :read, :update_config]
      for {_action, def} <- iface, do: assert(def.modes == [:call])
    end
  end

  describe "invoke(:read, ...)" do
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

    # NOTE: the pre-Lifecycle `:read` destroyed?-gate rejection test was
    # REMOVED — the process-dict gate DISAPPEARS under Lifecycle (SPEC
    # §2.3B: destroyed = absence of state). A `:read` is no longer
    # special-cased; the destroy path terminates the process so there is
    # no live process to race a stale read against.
  end

  describe "invoke(:update_config, ...)" do
    test "sets both fields in the slice (legacy 2-key write, leaves respawn_template_data alone)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}
      args = %{config_dir_path: "/tmp/agent-y", template_class: MyClass}

      assert {:ok, new_slice,
              %{
                config_dir_path: "/tmp/agent-y",
                template_class: MyClass,
                respawn_template_data: nil
              }} =
               invoke_via_new_contract(:update_config, slice, args, %{})

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
               invoke_via_new_contract(:update_config, slice, args, %{})

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
               invoke_via_new_contract(:update_config, slice, args, %{})

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
                 :update_config,
                 slice,
                 %{config_dir_path: 123, template_class: nil},
                 %{}
               )
    end

    test "rejects an invalid template_class type (non-atom, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:error, {:invalid_template_class, "ModString"}} =
               invoke_via_new_contract(
                 :update_config,
                 slice,
                 %{config_dir_path: nil, template_class: "ModString"},
                 %{}
               )
    end

    test "rejects an invalid respawn_template_data type (non-map, non-nil)" do
      slice = %{config_dir_path: nil, template_class: nil, respawn_template_data: nil}

      assert {:error, {:invalid_respawn_template_data, "not-a-map"}} =
               invoke_via_new_contract(
                 :update_config,
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
                 :update_config,
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

    # NOTE: the pre-Lifecycle `:update_config` destroyed?-gate rejection test
    # was REMOVED for the same reason as `:read` above (SPEC §2.3B — the
    # gate disappears; destroyed = absence of state).
  end

  describe "activate/2 (folds in the old post_init/handle_continue — SPEC §5/§10-R1)" do
    test "post_init/2 schedules the unified :ezagent_activate continuation (macro-emitted)" do
      # The pre-Lifecycle module returned `{:continue, {:setup_phase_tracking,
      # ...}}`; the Lifecycle macro now emits `{:continue, :ezagent_activate}`,
      # which runs the author's `activate/2`. The ensure-subprocess
      # logic moved INTO activate/2 (pre-`:ready`, no `send(self(), ...)`
      # self-deferral — §10-R1). The phase-topic subscribe is GONE (H1 —
      # the phase arrives point-to-point via Signal now).
      assert {:continue, :ezagent_activate} = Sandbox.post_init(%{}, %{})
    end

    test "activate/2 returns empty transients (H1: the phase subscription is gone)" do
      # nil template_class → no subprocess re-spawn attempted. Post-H1
      # (delete-holes #200) the Kind no longer subscribes to `pty:phase:` —
      # the phase arrives point-to-point via `EzagentActor.Signal.signal/2`,
      # so Sandbox has NO transients to rebuild.
      state = %{
        config_dir_path: nil,
        template_class: nil,
        respawn_template_data: nil,
        pty_phase: nil
      }

      ctx = %{self_uri: uniq_uri(), kind_module: SomeKind}

      assert {:ok, %{}} = Sandbox.activate(state, ctx)
    end

    test "activate/2 skips subprocess re-spawn when template_class lacks ensure_subprocess_alive/2" do
      # `Enum` is a stdlib module that does not export the callback — the
      # `should_ensure_subprocess?/2` probe path is exercised; activate
      # still returns cleanly (empty transients post-H1).
      state = %{
        config_dir_path: nil,
        template_class: Enum,
        respawn_template_data: %{},
        pty_phase: nil
      }

      ctx = %{self_uri: uniq_uri(), kind_module: SomeKind}

      assert {:ok, %{}} = Sandbox.activate(state, ctx)
    end

    test "activate/2 skips subprocess re-spawn when template_class is not an atom" do
      state =
        %{
          config_dir_path: nil,
          template_class: "not-atom",
          respawn_template_data: %{},
          pty_phase: nil
        }

      ctx = %{self_uri: uniq_uri(), kind_module: SomeKind}

      assert {:ok, %{}} = Sandbox.activate(state, ctx)
    end
  end

  describe "handle_signal/2 (PTY phase mirror — successor to handle_kind_message/3, SPEC §9 OQ-3)" do
    test "emits a {:set, :pty_phase, _} effect for a matching phase event" do
      # The phase value is DURABLE state (the snapshot-persisted LV-badge
      # mirror), so it is written via {:set, :pty_phase, _} — NOT a
      # transient. handle_signal returns the same effect list as a handler.
      agent_uri = uniq_uri()
      ctx = %{self_uri: agent_uri, kind_module: SomeKind}
      meta = %{os_pid: 12_345, reason: nil, at: 1_700_000_000_000}

      assert {:ok, effects} =
               Sandbox.handle_signal({:pty_phase, agent_uri, :running, meta}, ctx)

      assert effects == [{:set, :pty_phase, :running}]
    end

    test "ignores non-phase messages" do
      ctx = %{self_uri: uniq_uri()}

      assert :ignore = Sandbox.handle_signal(:something_else, ctx)
      assert :ignore = Sandbox.handle_signal({:not_a_phase, :foo}, ctx)
    end

    test "ignores phase events with invalid phase atoms (defensive)" do
      agent_uri = uniq_uri()
      ctx = %{self_uri: agent_uri}

      assert :ignore = Sandbox.handle_signal({:pty_phase, agent_uri, :bogus, %{}}, ctx)
    end

    test "ignores phase events whose agent_uri ≠ ctx.self_uri (codex MED-2 topic-collision defense)" do
      # PubSub topics are not an authentication boundary; a stray
      # publisher or topic collision could deliver a `{:pty_phase, X, ...}`
      # to a Kind whose self_uri is Y. Verify identity BEFORE emitting an
      # effect.
      self_uri = URI.new!("entity://system/agent/cc_self")
      foreign_uri = URI.new!("entity://system/agent/cc_other")
      ctx = %{self_uri: self_uri}

      assert :ignore = Sandbox.handle_signal({:pty_phase, foreign_uri, :dead, %{}}, ctx)
    end
  end

  # Unique URI per call so each `activate/2` subscribes to a distinct
  # PubSub topic (the test process subscribes; distinct topics avoid
  # cross-test interference under async).
  defp uniq_uri,
    do: URI.new!("entity://system/agent/cc_x-#{System.unique_integer([:positive])}")
end

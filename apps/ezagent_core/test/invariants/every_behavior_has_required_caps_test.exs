defmodule Ezagent.Invariants.EveryBehaviorHasRequiredCapsTest do
  @moduledoc """
  Invariant — every module declaring `@behaviour Ezagent.Behavior` MUST
  export `required_caps/0`, AND every action returned by `actions/0`
  MUST appear as a key in the cap map with a binary value.

  SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` §5.1 +
  §6.1 check 8-10.

  This is the PR-CC-2a invariant per `feedback_completion_requires_invariant_test`:
  PR-CC-2b (switch dispatch step 5.5 to read `required_caps/0`) is
  unblocked only when this test passes for every loaded Behavior.

  ## Probe set

  - P1: every loaded Behavior module exports `required_caps/0`.
  - P2: every action in `actions/0` is a key in `required_caps/0`.
  - P3: every value in `required_caps/0` is a binary cap string.
  - P4: every key in `required_caps/0` is in `actions/0` (no extras).
  """
  use ExUnit.Case, async: true

  @behaviour_modules [
    # ezagent_core
    Ezagent.Behavior.Lifecycle,
    Ezagent.Behavior.Notifications,
    Ezagent.Behavior.Presence,
    Ezagent.Behavior.Routing,
    Ezagent.Behavior.Sandbox,
    # ezagent_domain_chat
    Ezagent.Behavior.Chat,
    Ezagent.Behavior.Template,
    Ezagent.Behavior.Publisher.SessionImpl,
    # ezagent_domain_external_mirror
    Ezagent.Behavior.ExternalMirror,
    Ezagent.Behavior.ExternalMirrorWorker,
    # ezagent_domain_identity
    Ezagent.Behavior.Identity,
    Ezagent.Behavior.IdentityAdmin,
    Ezagent.Behavior.ApiKeys,
    # ezagent_domain_pty
    Ezagent.Behavior.Pty,
    # ezagent_domain_workspace
    Ezagent.Behavior.Workspace,
    # plugins
    Ezagent.Behavior.Echo,
    Ezagent.Behavior.CurlAgent,
    Ezagent.Behavior.NpAgent,
    EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow
  ]

  describe "P1: every @behaviour Ezagent.Behavior module exports required_caps/0" do
    for behavior <- @behaviour_modules do
      test "#{inspect(behavior)} exports required_caps/0" do
        Code.ensure_loaded?(unquote(behavior))

        assert function_exported?(unquote(behavior), :required_caps, 0),
               "#{inspect(unquote(behavior))} declares @behaviour Ezagent.Behavior " <>
                 "but does not export required_caps/0. " <>
                 "SPEC caps-cleanup-v1 §5.1 — add a required_caps/0 declaration."
      end
    end
  end

  describe "P2: every actions/0 key appears in required_caps/0" do
    for behavior <- @behaviour_modules do
      test "#{inspect(behavior)} required_caps/0 keys ⊇ actions/0" do
        Code.ensure_loaded?(unquote(behavior))
        b = unquote(behavior)

        if function_exported?(b, :required_caps, 0) and function_exported?(b, :actions, 0) do
          actions = MapSet.new(b.actions())
          keys = MapSet.new(Map.keys(b.required_caps()))
          missing = MapSet.difference(actions, keys)

          assert MapSet.size(missing) == 0,
                 "#{inspect(b)}: required_caps/0 missing keys for actions: " <>
                   "#{inspect(MapSet.to_list(missing))} " <>
                   "(SPEC caps-cleanup-v1 §6 check 9)"
        end
      end
    end
  end

  describe "P3: every required_caps/0 value is a binary cap string" do
    for behavior <- @behaviour_modules do
      test "#{inspect(behavior)} required_caps/0 values are all binaries" do
        Code.ensure_loaded?(unquote(behavior))
        b = unquote(behavior)

        if function_exported?(b, :required_caps, 0) do
          non_strings =
            b.required_caps()
            |> Enum.reject(fn {_action, cap} -> is_binary(cap) end)

          assert non_strings == [],
                 "#{inspect(b)}: required_caps/0 has non-string values: " <>
                   "#{inspect(non_strings)} (SPEC caps-cleanup-v1 §6 check 10)"
        end
      end
    end
  end

  describe "P4: every required_caps/0 key appears in actions/0 (no extras)" do
    for behavior <- @behaviour_modules do
      test "#{inspect(behavior)} required_caps/0 keys ⊆ actions/0" do
        Code.ensure_loaded?(unquote(behavior))
        b = unquote(behavior)

        if function_exported?(b, :required_caps, 0) and function_exported?(b, :actions, 0) do
          actions = MapSet.new(b.actions())
          keys = MapSet.new(Map.keys(b.required_caps()))
          extra = MapSet.difference(keys, actions)

          assert MapSet.size(extra) == 0,
                 "#{inspect(b)}: required_caps/0 has extra keys not in actions/0: " <>
                   "#{inspect(MapSet.to_list(extra))} " <>
                   "(SPEC caps-cleanup-v1 §6 check 9)"
        end
      end
    end
  end

  describe "cap strings parse with Ezagent.Cap matcher" do
    test "all declared cap strings can match a synthesized needed cap" do
      # Smoke test: each declared cap string should at least parse +
      # match itself via Ezagent.Cap.matches?/2.
      for behavior <- @behaviour_modules,
          Code.ensure_loaded?(behavior),
          function_exported?(behavior, :required_caps, 0),
          {_action, cap_string} <- behavior.required_caps() do
        assert Ezagent.Cap.matches?(cap_string, cap_string),
               "#{inspect(behavior)}: cap_string #{inspect(cap_string)} " <>
                 "fails to self-match via Ezagent.Cap.matches?/2"
      end
    end
  end
end

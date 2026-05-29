defmodule EzagentCore.Invariants.DispatchUsesRequiredCapsStructTest do
  @moduledoc """
  PR-CC-2-v2 §10(c) — dispatch step 5.5 (the authz chokepoint) MUST
  read `behavior.required_caps/0` + `Kind.holds_cap?/2` to authorize
  an invocation. The old path (`Capability.cap_for_action/3` + plain
  `Capability.matches?/2` against `ctx.caps`) is the LEGACY fallback
  for Behaviors that haven't declared `required_caps/0` yet (test
  support shims); production Behaviors MUST declare.

  This invariant verifies the runtime module's source references the
  required-caps reading + Kind.holds_cap? gateway. A future refactor
  that drops either reference would regress the structural goal of
  this PR — every dispatch passes through the declarative-cap
  chokepoint.

  See SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §10(g).
  """

  use ExUnit.Case, async: true

  defp umbrella_root, do: Path.expand("../../../..", __DIR__)

  defp runtime_path,
    do: Path.join(umbrella_root(), "apps/ezagent_core/lib/ezagent/kind/runtime.ex")

  test "Ezagent.Kind.Runtime references behavior.required_caps()" do
    source = File.read!(runtime_path())

    assert source =~ "behavior_module.required_caps()",
           "runtime.ex must call behavior_module.required_caps() at step 5.5"
  end

  test "Ezagent.Kind.Runtime references Ezagent.Kind.holds_cap?/3" do
    source = File.read!(runtime_path())

    assert source =~ "Ezagent.Kind.holds_cap?",
           "runtime.ex must call Ezagent.Kind.holds_cap?/3 at step 5.5"
  end

  test "Ezagent.Kind.Runtime references Behavior.workspace_scoped?/1" do
    source = File.read!(runtime_path())

    assert source =~ "Ezagent.Behavior.workspace_scoped?",
           "runtime.ex must consult Behavior.workspace_scoped?/1 at step 5.6"
  end

  test "every production Behavior implements required_caps/0" do
    # Find every module with `@behaviour Ezagent.Behavior` exact match
    # in apps/*/lib (excluding test/ + the @callback declaration file).
    paths = Path.wildcard(Path.join(umbrella_root(), "apps/*/lib/**/*.ex"))

    behavior_modules =
      for path <- paths,
          content = File.read!(path),
          # Direct line-anchored match — avoids picking up
          # `@behaviour Ezagent.Behavior.Publisher` and similar
          # sub-behaviour declarations.
          Regex.match?(~r/^\s*@behaviour Ezagent\.Behavior\s*$/m, content),
          # Skip the @callback declaration file itself.
          not String.ends_with?(path, "lib/ezagent/behavior.ex"),
          # Skip the Lifecycle macro (SPEC 2026-05-29) — it EMITS
          # `@behaviour Ezagent.Behavior` inside its `__using__` quote
          # block (so the line-anchored regex matches the macro source),
          # but `required_caps/0` is injected for the USING module by
          # `use Ezagent.Behavior`'s @before_compile, not defined here.
          # Same class of exclusion as behavior.ex above.
          not String.ends_with?(path, "lib/ezagent/lifecycle.ex"),
          do: path

    refute behavior_modules == [],
           "test setup: expected at least one production Behavior under apps/*/lib"

    missing =
      for path <- behavior_modules,
          content = File.read!(path),
          not Regex.match?(~r/def\s+required_caps\b/, content),
          do: path

    assert missing == [],
           "Behaviors missing required_caps/0:\n  " <>
             Enum.join(missing, "\n  ") <>
             "\nSee SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2."
  end
end

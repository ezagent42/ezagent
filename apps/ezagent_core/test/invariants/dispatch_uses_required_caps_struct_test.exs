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
    # SPEC 2026-05-29 (lifecycle migration): developer Behaviors are now
    # authored via `use Ezagent.Lifecycle` (or the engine `use
    # Ezagent.Behavior`), which EMITS `@behaviour Ezagent.Behavior`
    # inside the macro's `__using__` quote — so a static source-grep for
    # a line-anchored `@behaviour Ezagent.Behavior` literal no longer
    # finds production Behaviors (only the macro source itself). Discover
    # via runtime reflection instead: every loaded module that declares
    # the `Ezagent.Behavior` behaviour is a production Behavior, and the
    # macro's @before_compile injects `required_caps/0` for it. This
    # check verifies the function is actually exported (catches a
    # regression where the macro stops injecting it, or a hand-rolled
    # engine Behavior omits it).
    #
    # NB: reflection only sees loaded modules — this assertion is
    # meaningful under the full umbrella `mix test` (all apps loaded);
    # ensure the umbrella apps are loaded so a solo run still discovers
    # them.
    for app <- umbrella_apps() do
      _ = Application.load(app)
      _ = Application.ensure_all_started(app)
    end

    behavior_modules =
      for {module, _file} <- :code.all_loaded(),
          Ezagent.Behavior in module_behaviours(module),
          # The engine macro module + the Lifecycle macro module declare
          # the behaviour on themselves but are not production Behaviors.
          module not in [Ezagent.Behavior, Ezagent.Lifecycle],
          # PRODUCTION only — the original source-scan deliberately
          # excluded `test/`. Reflection over `:code.all_loaded` also sees
          # test-fixture mock Behaviors (e.g. CapabilityRegistryTest's
          # Mock* modules) loaded by concurrent suites; those legitimately
          # omit required_caps/0. Filter to modules whose compile source
          # lives under `apps/*/lib/`.
          production_behavior_source?(module),
          do: module

    refute behavior_modules == [],
           "test setup: expected at least one production Behavior loaded " <>
             "(run the full umbrella `mix test` so all apps' Behaviors are loaded)"

    missing =
      for module <- behavior_modules,
          not function_exported?(module, :required_caps, 0),
          do: module

    assert missing == [],
           "Behaviors missing required_caps/0:\n  " <>
             Enum.map_join(missing, "\n  ", &inspect/1) <>
             "\nSee SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2."
  end

  # All umbrella OTP apps (each app dir under apps/ with a matching
  # mix.exs) — used to force-load Behaviors before reflection.
  defp umbrella_apps do
    Path.join(umbrella_root(), "apps/*/mix.exs")
    |> Path.wildcard()
    |> Enum.map(fn mix_path ->
      mix_path |> Path.dirname() |> Path.basename() |> String.to_atom()
    end)
  end

  # True when the module was compiled from a source file under an
  # `apps/*/lib/` path — i.e. it is production code, not a `test/`
  # fixture. Mirrors the original source-scan's lib-only scoping.
  defp production_behavior_source?(module) do
    case module_source(module) do
      nil -> false
      source -> Regex.match?(~r{/apps/[^/]+/lib/}, to_string(source))
    end
  end

  defp module_source(module) do
    if function_exported?(module, :module_info, 1) do
      try do
        module.module_info(:compile)[:source]
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  # Behaviours a module declares, robust against modules whose
  # `__info__/1` is unavailable (bootstrap/erlang modules).
  defp module_behaviours(module) do
    if function_exported?(module, :__info__, 1) do
      try do
        module.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()
      rescue
        _ -> []
      end
    else
      []
    end
  end
end

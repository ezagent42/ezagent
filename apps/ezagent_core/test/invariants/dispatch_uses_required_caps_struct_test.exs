defmodule EzagentCore.Invariants.DispatchUsesRequiredCapsStructTest do
  @moduledoc """
  Dispatch step 5.5 MUST delegate to the target Kind's central capability
  verifier. The verifier derives the concrete required capability, matches
  the immutable intent, and verifies the target authority signature. Runtime
  must not retain a parallel `Kind.holds_cap?` authorization path.

  See SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §10(g).
  """

  use ExUnit.Case, async: true

  defp umbrella_root, do: Path.expand("../../../..", __DIR__)

  defp runtime_path,
    do: Path.join(umbrella_root(), "apps/ezagent_core/lib/ezagent/kind/runtime.ex")

  defp verifier_path,
    do: Path.join(umbrella_root(), "apps/ezagent_core/lib/ezagent/cap/verifier.ex")

  test "Runtime delegates authorization to the central verifier" do
    source = File.read!(runtime_path())

    assert source =~ "Ezagent.Cap.Verifier.authorize("
    refute source =~ "Ezagent.Kind.holds_cap?"
  end

  test "central verifier binds action intent and delegates to authorize/3" do
    source = File.read!(verifier_path())

    assert source =~ "needed = required_cap(kind_module, behavior_module, action, target)"
    assert source =~ "Ezagent.Cap.authorize(holder, candidates, needed)"
    refute source =~ "Enum.find(verified, &Capability.matches?(&1, needed))"
  end

  test "Ezagent.Kind.Runtime references Behavior.workspace_scoped?/1" do
    source = File.read!(runtime_path())

    assert source =~ "Ezagent.ActionSet.workspace_scoped?",
           "runtime.ex must consult Behavior.workspace_scoped?/1 at step 5.6"
  end

  test "every production Behavior implements required_caps/0" do
    # SPEC 2026-05-29 (lifecycle migration): developer Behaviors are now
    # authored via `use Ezagent.Lifecycle` (or the engine `use
    # Ezagent.ActionSet`), which EMITS `@behaviour Ezagent.ActionSet`
    # inside the macro's `__using__` quote — so a static source-grep for
    # a line-anchored `@behaviour Ezagent.ActionSet` literal no longer
    # finds production Behaviors (only the macro source itself). Discover
    # via runtime reflection instead: every loaded module that declares
    # the `Ezagent.ActionSet` behaviour is a production Behavior, and the
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
          Ezagent.ActionSet in module_behaviours(module),
          # The engine macro module + the Lifecycle macro module declare
          # the behaviour on themselves but are not production Behaviors.
          module not in [Ezagent.ActionSet, Ezagent.Lifecycle],
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

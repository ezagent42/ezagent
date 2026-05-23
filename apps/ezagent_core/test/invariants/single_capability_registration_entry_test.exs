defmodule EzagentCore.Invariants.SingleCapabilityRegistrationEntryTest do
  @moduledoc """
  Single-entry invariant for cap-subject + dispatch registration.

  Per SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md`
  §6 + Allen's "registry 是唯一入口，不允许被绕过" directive:

  - `Ezagent.BehaviorRegistry.register/3` (the bare ETS insert) is
    `@doc false` and FORBIDDEN in production code outside
    `apps/ezagent_core/lib/ezagent/capability_registry.ex`. Tests can
    call it directly (the scan excludes `test/`).
  - This test scans all production code paths and asserts only ONE
    call site exists: the legitimate one inside CapabilityRegistry.

  Mirrors the pattern of `single_spawn_entry_test.exs`.

  Why this matters: without the gate, future code can re-introduce
  cap-subject drift (write dispatch wiring without writing the cap
  subject, or write a description-less cap subject the admin UI
  can't render). The drift was the existing condition before PR-CR.
  """

  use ExUnit.Case, async: true

  @forbidden_call ~r/Ezagent\.BehaviorRegistry\.register\(|(?<![\.\w])BehaviorRegistry\.register\(/

  # The single legitimate call site inside CapabilityRegistry's
  # `register/3` body (this is HOW it preserves the dispatch wiring
  # invariant). Any OTHER hit in production code is a violation.
  @allowlist [
    "apps/ezagent_core/lib/ezagent/capability_registry.ex"
  ]

  test "only Ezagent.CapabilityRegistry source calls BehaviorRegistry.register/3 in production" do
    apps_root = Path.expand("../../../..", __DIR__)
    production_files = list_production_files(apps_root)

    violations =
      Enum.flat_map(production_files, fn rel_path ->
        full = Path.join(apps_root, rel_path)

        # Strip single-line comments (`#...` at line start with optional
        # leading whitespace) before scanning — Elixir comments may mention
        # the function name as documentation, e.g. legacy chat.ex:648
        # describes the BehaviorRegistry.register pattern in a moduledoc.
        content =
          full
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
          |> Enum.join("\n")

        if Regex.match?(@forbidden_call, content) and rel_path not in @allowlist do
          [rel_path]
        else
          []
        end
      end)

    assert violations == [],
           """
           Direct `BehaviorRegistry.register/3` calls in production code outside
           `Ezagent.CapabilityRegistry`:

             #{Enum.join(violations, "\n             ")}

           Use `Ezagent.CapabilityRegistry.register(kind, action, behavior)` instead.
           See SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md` §2.
           """
  end

  defp list_production_files(apps_root) do
    apps_root
    |> Path.join("apps")
    |> File.ls!()
    |> Enum.flat_map(fn app ->
      lib_dir = Path.join(["apps", app, "lib"])
      full_lib = Path.join(apps_root, lib_dir)

      if File.dir?(full_lib) do
        Path.wildcard(Path.join(full_lib, "**/*.ex"))
        |> Enum.map(&Path.relative_to(&1, apps_root))
      else
        []
      end
    end)
  end
end

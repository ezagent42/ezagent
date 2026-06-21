defmodule Ezagent.Invariants.AuditWriterTestEnvIsolationTest do
  @moduledoc """
  Pins the 2026-05-26 C-snapshot decision: `Ezagent.Audit.Writer` and
  `Ezagent.Snapshot.Writer` MUST be in the production supervision tree
  (Decision #60 — observability + invoke hot-path amortisation) and
  MUST NOT be auto-started under `Mix.env() == :test`.

  Background: both writers are global singleton GenServers with a 100ms
  timer-driven `Repo.insert_all` / `Repo.insert!` flush. Against
  `Ecto.Adapters.SQL.Sandbox`'s per-test ownership lifecycle their
  async flush stamps over connections owned by tests that have already
  exited, surfacing as "Database busy" + "owner exited" errors that
  bleed into subsequent unrelated tests (the 4 `SnapshotTest` failures plus
  operator UI baseline flakes). Tests that need the writers opt in via
  `use Ezagent.Test.AuditCase`.

  Per `feedback_completion_requires_invariant_test` — the architectural
  goal is "writer behaviour drifts cannot silently re-introduce the
  flake class". This test fails loudly if someone:

    a. Removes the writer from prod children (regressing audit observability)
    b. Adds the writer back to test children (regressing test isolation)
    c. Tries to introduce a third async writer without updating the allowlist

  ## Why we don't `start_supervised` Application here

  This test parses the source of `EzagentCore.Application.start/2`
  statically. Starting another `EzagentCore.Application` inside the
  test would race against the already-running one and the global
  supervisor name `EzagentCore.Supervisor`. Static parse is sufficient
  because the test catches the case where someone deletes the
  `|> Enum.reject(&skip_in_test_env?/1)` pipe (which IS the test gate).
  """

  use ExUnit.Case, async: true

  @application_path Path.expand(
                      "../../lib/ezagent_core/application.ex",
                      __DIR__
                    )

  @writers ["Ezagent.Audit.Writer", "Ezagent.Snapshot.Writer"]

  test "production children list literally contains both async writers (regression gate)" do
    source = File.read!(@application_path)

    for writer <- @writers do
      assert source =~ ~r/^\s*#{Regex.escape(writer)},?\s*$/m,
             """
             `#{writer}` MUST appear as a child in `EzagentCore.Application.start/2`.
             Audit + observability (Decision #60) and `:periodic` snapshot writes
             depend on it. If you intentionally removed the writer, you have changed
             production behaviour — update this invariant test AND the writer's
             callers AND the SPEC, then re-land.
             """
    end
  end

  test "test-env filter retains both writers in the skip allowlist" do
    source = File.read!(@application_path)

    # Find the literal allowlist module attribute and parse its members.
    [_, list_body] =
      Regex.run(~r/@writers_skipped_in_test\s+\[([^\]]*)\]/, source) ||
        flunk(
          "@writers_skipped_in_test attribute not found — the test-env gate that " <>
            "keeps Audit.Writer + Snapshot.Writer out of sandbox-poisoning has " <>
            "been removed."
        )

    members =
      list_body
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    assert "Ezagent.Audit.Writer" in members,
           "Audit.Writer must be in the test-env skip allowlist (sandbox-ownership lifecycle)."

    assert "Ezagent.Snapshot.Writer" in members,
           "Snapshot.Writer must be in the test-env skip allowlist (sandbox-ownership lifecycle)."
  end

  test "filter pipe is invoked on the children list" do
    source = File.read!(@application_path)

    assert source =~ ~r/\|>\s*Enum\.reject\(&skip_in_test_env\?\/1\)/,
           """
           The `children` list must be piped through `Enum.reject(&skip_in_test_env?/1)`
           to apply the test-env skip allowlist. Without this filter the writers
           start under `:test` and trigger SQLite Sandbox "Database busy" flakes.
           """
  end

  test "in test env, the writers are NOT alive" do
    # Runtime confirmation matching the static gate.
    refute Process.whereis(Ezagent.Audit.Writer),
           "Ezagent.Audit.Writer must NOT be running in test env (use AuditCase to opt in)."

    refute Process.whereis(Ezagent.Snapshot.Writer),
           "Ezagent.Snapshot.Writer must NOT be running in test env (use AuditCase to opt in)."
  end
end

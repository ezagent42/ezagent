defmodule EzagentCore.Invariants.NoAdvisorBehaviorLiteralTest do
  @moduledoc """
  Elimination gate for the `advisor.behavior` → `agent.soul` config-key rename
  (SPEC `docs/together/2026-06-26/specs/soul-config-key-rename.md`).

  The default config-cascade key was renamed because `advisor` was misleading
  historical residue (the retired advisor-demo's key). The rename's load-bearing
  invariant: **no production code may reference the old literal
  `"advisor.behavior"` anymore** — including the drift trap at
  `identity_data.ex` that previously RE-HARDCODED the string instead of reading
  `Ezagent.Agent.Config.default_key/0`.

  This is the failing-when-violated test (per
  `feedback_completion_requires_invariant_test`) that makes the rename's "done"
  claim load-bearing: any future PR that re-introduces the literal in lib code
  fails here.

  ## Exemptions

  - Probes `apps/*/lib/**/*.ex` only (production code). Historical design specs
    under `docs/` that document the OLD name are annotated, not rewritten.
  - The canonical source of the new key is `Ezagent.Agent.Config.default_key/0`;
    the data-rename module `Ezagent.Socialware.ConfigKeyRename` legitimately
    NAMES the old literal in `old_key/0` (the from-side of the rename) — but it
    builds it from its own `@old` module attribute string, so it is the ONE
    sanctioned occurrence and is exempted by path.
  """

  use ExUnit.Case, async: true

  @sanctioned "apps/ezagent_domain_identity/lib/ezagent/socialware/config_key_rename.ex"

  test "no production lib code references the literal \"advisor.behavior\"" do
    offenders =
      Path.wildcard("apps/*/lib/**/*.ex")
      |> Enum.reject(&String.ends_with?(&1, @sanctioned))
      |> Enum.filter(fn path -> File.read!(path) =~ "advisor.behavior" end)

    assert offenders == [],
           "config-key rename leak — these files still reference the old " <>
             "literal \"advisor.behavior\": " <>
             inspect(offenders) <>
             ". The default key is now \"agent.soul\"; read it via " <>
             "Ezagent.Agent.Config.default_key/0 (never re-hardcode the string)."
  end

  test "Ezagent.Agent.Config.default_key/0 is the canonical agent.soul source" do
    Code.ensure_loaded?(Ezagent.Agent.Config)

    assert function_exported?(Ezagent.Agent.Config, :default_key, 0),
           "the canonical default-key accessor must exist so out-of-app readers " <>
             "reference it instead of re-hardcoding the literal"

    assert Ezagent.Agent.Config.default_key() == "agent.soul"
  end
end

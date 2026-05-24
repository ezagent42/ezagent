defmodule Ezagent.Invariants.NotificationSubscriptionsSystemCallsiteTest do
  @moduledoc """
  Codex PR-N1 round-3 CRITICAL fix invariant.

  `Ezagent.NotificationSubscriptions.system_register/2` and
  `system_unregister/2` bypass the cap check by design — they're
  the bootstrap / infrastructure path. The runtime cap-skip happens
  via a distinct GenServer message tag (`:system_register` /
  `:system_unregister`) which CANNOT be forged through the public
  `ctx`-based API (round-3 fix moved the bypass off ctx).

  But the helpers themselves are public Elixir functions — any
  module can call `Ezagent.NotificationSubscriptions.system_register/2`.
  That's intentional (no compile-time protection from a determined
  caller) but the audit boundary is THIS test: an allowlist of
  modules that may grep-match.

  When a NEW module legitimately needs system_register, ADD it to
  `@allowed_callers`. When an existing entry no longer needs it,
  REMOVE it. The intent is to force code review to walk the audit
  trail.
  """
  use ExUnit.Case, async: true

  @allowed_callers [
    # The module itself can self-reference in moduledoc + via tests.
    "apps/ezagent_core/lib/ezagent/notification_subscriptions.ex",
    # Tests assert the helpers exist.
    "apps/ezagent_core/test/ezagent/notification_subscriptions_test.exs",
    # This invariant test itself contains the function name (in moduledoc).
    "apps/ezagent_core/test/invariants/notification_subscriptions_system_callsite_test.exs"
    # Add bootstrap call sites here as they land (PR-N2 LV mount
    # re-subscriptions, PR-N5 chat producer migration etc).
  ]

  test "only allowlisted files call Ezagent.NotificationSubscriptions.system_register/2 or system_unregister/2" do
    # `__DIR__` = apps/ezagent_core/test/invariants
    # 4 levels up → repo root (apps/ezagent_core/test/invariants
    # → test/invariants → invariants → ezagent_core → apps → repo)
    # Actually 4 .. = ezagent_core/.. = apps/.. = repo root.
    repo_root = Path.expand("../../../..", __DIR__)

    # grep exit-1 = "no matches found", which would be a bug (we
    # always expect the moduledoc + tests to match). Accept exit
    # 0 (matches) or 1 (no matches — surfaced via empty stdout
    # and treated as "no callers, no violation").
    {grep_out, exit_code} =
      System.cmd(
        "grep",
        [
          "-rln",
          "--include=*.ex",
          "--include=*.exs",
          "NotificationSubscriptions.system_",
          "apps"
        ],
        cd: repo_root,
        stderr_to_stdout: true
      )

    assert exit_code in [0, 1],
           "grep failed with exit #{exit_code}; output:\n#{grep_out}"

    callers =
      grep_out
      |> String.split("\n", trim: true)
      |> Enum.map(&Path.relative_to(&1, ""))
      |> Enum.uniq()
      |> Enum.sort()

    unauthorized = callers -- @allowed_callers

    assert unauthorized == [],
           """
           New callers of `Ezagent.NotificationSubscriptions.system_*`
           detected — system-bypass helpers must stay grep-auditable.

           Either:
             (a) the new caller is bootstrap / infrastructure → add
                 it to `@allowed_callers` in this test with a comment
                 explaining the audit rationale
             (b) the new caller should use the public cap-gated
                 `register_subscription/3` API → fix the call site

           Unauthorized callers:
             #{Enum.join(unauthorized, "\n  ")}

           Codex PR-N1 round-3 CRITICAL audit boundary —
           docs/superpowers/specs/2026-05-24-notification-architecture-v2.md.
           """
  end
end

defmodule EzagentCore.Invariants.NoMessageMultiRoutingTest do
  @moduledoc """
  Regression lock for the message session-scoping collapse (2026-06-21).

  Messages are session-scoped: one `messages` row per session, keyed by
  `messages.session_uri`. Cross-session forwarding copies a NEW message into the
  target session (+ `ref_id` for navigation) — it MUST NOT re-introduce the
  removed `message_routings` multi-routing (one `message_id` in multiple sessions
  via a join table). That capability was verified vestigial and removed; this gate
  prevents it (and its perf/identity costs) from creeping back.

  Forbids re-introducing the `Ezagent.MessageRouting` schema or querying a
  `message_routings` table in `lib/` CODE (the schema module, an Ecto `in`/struct
  reference, an alias, or a quoted-table query) — NOT prose mentions (a comment
  noting "the routing join table was removed" is fine). Migrations and docs are
  naturally excluded (only `apps/*/lib/**/*.ex` is scanned).
  """
  use ExUnit.Case, async: true

  @pattern ~r/defmodule\s+Ezagent\.MessageRouting\b|\bin\s+MessageRouting\b|%MessageRouting\{|alias[^\n]*\bMessageRouting\b|in\s+"message_routings"|table\(:message_routings\)/

  test "no lib reference re-introduces message multi-routing" do
    umbrella_root = Path.expand("../../../..", __DIR__)
    files = Path.wildcard(Path.join(umbrella_root, "apps/*/lib/**/*.ex"))

    offenders =
      for path <- files,
          content = File.read!(path),
          Regex.match?(@pattern, content),
          do: path

    assert offenders == [],
           "message multi-routing re-introduced (message session-scoping was collapsed " <>
             "2026-06-21). Messages are session-scoped (messages.session_uri); cross-session " <>
             "forwarding copies a NEW message, never shared-id routing. Offending files:\n  " <>
             Enum.join(offenders, "\n  ")
  end
end

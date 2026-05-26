defmodule EzagentCore.Invariants.LvCliParityTest do
  @moduledoc """
  Cross-domain CLI ↔ LV parity invariant — enumerates **every** mutating
  `handle_event/3` clause across **every** LiveView and asserts each
  has a corresponding `mix ezagent <kind> <action>` or `mix ezagent.*`
  legacy task counterpart.

  Companion to the narrower
  `EzagentCore.Invariants.WorkspaceLvCliParityTest` (PR #344) which
  covers only `Ezagent.Workspace.*` operations. This invariant is the
  broader gate: it walks every LV file, parses every `handle_event`
  binding name, and demands an explicit row in this test's mapping
  table.

  ## Why an explicit mapping table

  Greppin' for `mix ezagent <action>` would over-match (any string can
  appear in a comment) and miss auto-derived commands (those are only
  defined by `Behavior.interface/0`, not the filesystem). The mapping
  is what an operator should be able to type — verified once at code-
  review time, then locked in by this test.

  Adding a new LV `handle_event(<name>, ...)` clause without adding
  the corresponding row in `@event_to_cli` will FAIL this test. That
  is the point: per Allen 2026-05-25
  (`feedback_completion_requires_invariant_test`), parity work isn't
  "done" until the architectural goal is enforced by a regression test.

  ## Categories

  - `:cli` — has a `mix ezagent` or `mix ezagent.*` counterpart (mapped
    string is the operator-facing command shape).
  - `:ui_only` — pure UI state (filter / toggle / switch view / pagination)
    — exempt from CLI parity by design.
  - `:pty_stream` — terminal byte input / resize — uses
    `Behavior.Pty` which is reachable from CLI via `mix ezagent agent write`
    but the LV path is real-time keystroke streaming so the CLI parity
    is unidirectional (you can drive a PTY from CLI to seed input but
    operating a TUI from one-shot mix tasks is impractical).
  - `:deferred` — known gap; row carries the docs/futures/todo.md
    bullet path so future PRs can find it. Per Allen
    (`feedback_dont_defer_what_is_solvable_now`), every `:deferred`
    entry should justify why the gap exists vs being immediately
    closable.

  ## How to update

  When you add a new LV `handle_event("foo", ...)` clause:
  1. Run this test — it will fail listing `"foo"` as unmapped.
  2. Add a row to `@event_to_cli`:
     - If your action goes via dispatch, the CLI is `mix ezagent <kind>
       <action>` — auto-derived from `Behavior.interface/0`.
     - If your action is pure UI state, use category `:ui_only`.
     - If you genuinely cannot land a CLI in the same PR (rare —
       prefer landing the Behavior action), category `:deferred`
       with a docs path.
  3. Re-run — green.
  """
  use ExUnit.Case, async: true

  @lv_dir Path.join([
            File.cwd!(),
            "../../apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview"
          ])

  # The canonical mapping. Each entry: event_name => {category, cli_or_reason}.
  # When you add a new `handle_event`, you MUST add a row here.
  # Source-of-truth survey: 2026-05-26, all 22 LV files.
  @event_to_cli %{
    # --- Workspace ops (parity covered by workspace_lv_cli_parity_test too) ---
    "create_workspace" => {:cli, "mix ezagent workspace create <name>"},
    "add_member" => {:cli, "mix ezagent.workspace.add_member <name> <uri>"},
    "remove_member" => {:cli, "mix ezagent.workspace.remove_member <name> <uri>"},
    "add_template" => {:cli, "mix ezagent.workspace.add_template <name> <tmpl-json>"},
    "remove_template" => {:cli, "mix ezagent.workspace.remove_template <name> <tmpl-name>"},
    # promote_to_system + revoke_system are alias for system-workspace
    # add_member/remove_member; CLI is the same workspace.* tasks with
    # `system` as the workspace name.
    "promote_to_system" => {:cli, "mix ezagent.workspace.add_member system <uri>"},
    "revoke_system" => {:cli, "mix ezagent.workspace.remove_member system <uri>"},

    # --- Agent ops ---
    # create_agent goes via Behavior.Workspace :create_agent dispatch
    # (PR-AC-1 single-path invariant); the operator CLI is the legacy
    # task which itself dispatches via the same action body.
    "create_agent" => {:cli, "mix ezagent.agent.create <agent-uri> --caps ..."},
    # restart is auto-derived from Behavior.Lifecycle :terminate +
    # supervisor restart policy.
    "restart" => {:cli, "mix ezagent agent terminate --agent <uri>"},
    # restart_pty (PTY-phase-state-machine 2026-05-26 follow-up b) —
    # operator clicks the "Dead — Restart" phase badge in TerminalLive.
    # Dispatches `?action=lifecycle.terminate` on the agent URI, same
    # CLI counterpart as the `restart` button above (single CLI path
    # per the auto-derived rule; the LV surfaces it twice for UX).
    "restart_pty" => {:cli, "mix ezagent agent terminate --agent <uri>"},

    # --- Session / chat ops ---
    "invite_member" =>
      {:cli, "mix ezagent session join --session <uri> --member <member-uri>"},
    # chat_compose CLI is partial — text-only via `mix ezagent session send`.
    # File attachments + mentions are not yet representable in argv. See
    # `docs/notes/2026-05-24-cli-gui-parity-audit.md` §1 row 1.
    "chat_compose" =>
      {:deferred,
       "docs/futures/todo.md — chat_compose attachment shapes need a `resource://` upload primitive"},
    # create_session — LV calls EzagentDomainChat.create_session/3
    # directly (bypasses dispatch in BOTH surfaces per audit Finding 1).
    # CLI gap: no `mix ezagent session create` yet. Tracked.
    "create_session" =>
      {:deferred,
       "docs/futures/todo.md — HIGH-3 admin_live.create_session needs a Behavior + action (likely on Workspace Kind: :create_session, parallels :create_agent)"},

    # --- Routing ops (Behavior.Routing covers all 4 actions auto-deriving) ---
    "add_rule" => {:cli, "mix ezagent workspace add_rule --workspace <name> ..."},
    "delete_rule" => {:cli, "mix ezagent workspace delete_rule --workspace <name> ..."},
    "disable_rule" => {:cli, "mix ezagent workspace disable_rule --workspace <name> ..."},
    "enable_rule" => {:cli, "mix ezagent workspace enable_rule --workspace <name> ..."},
    # routing_rule_add_session (admin_live) — session-scoped variant of
    # add_rule. Maps to `mix ezagent session add_rule --session <uri> ...`
    # which auto-derives from Behavior.Routing registered on Session Kind.
    "routing_rule_add_session" =>
      {:cli, "mix ezagent session add_rule --session <uri> --table ... --matcher-json ... --receivers ..."},
    # routing_rule_toggle — admin_live's per-row enable/disable. Maps to
    # `mix ezagent workspace disable_rule` / `enable_rule`.
    "routing_rule_toggle" =>
      {:cli, "mix ezagent workspace disable_rule / enable_rule (depending on toggle target)"},

    # --- Identity ops ---
    # HIGH-2 completion (2026-05-26): `:create_user` action landed on
    # Behavior.Workspace; `mix ezagent workspace create_user` auto-derives
    # from interface/0. Legacy `mix ezagent.user.create` retained for
    # muscle memory but now prints a deprecation notice.
    "create_user" =>
      {:cli,
       "mix ezagent workspace create_user --workspace <name> --user-uri <uri> --password <pw> --caps <list>"},
    # HIGH-2 completion (2026-05-26): `:set_password` action landed on
    # the new `Ezagent.Behavior.UserCredentials` registered on User
    # Kind. Auto-derives `mix ezagent user set_password`. Legacy
    # `mix ezagent.user.set_password` retained as the admin-bootstrap
    # carve-out (chicken-and-egg: admin needs a password BEFORE they
    # can mint a token for `mix ezagent` calls).
    "set_password" =>
      {:cli, "mix ezagent user set_password --user <uri> --password <pw>"},
    # display_name save — LV calls Ezagent.Entity.Profile.upsert/1
    # directly. Needs a Behavior on User Kind: :set_display_name
    # (or extend Behavior.Identity). Profile is its own slice today.
    "save_display_name" =>
      {:deferred,
       "docs/futures/todo.md HIGH-3 — needs Behavior on User Kind for :set_display_name (Profile slice); LV path uses Ezagent.Entity.Profile.upsert/1 directly"},
    # grant_cap / revoke_cap exist on Behavior.IdentityAdmin AND are
    # used by entity_caps_live via dispatch. mix ezagent auto-derives.
    "grant" => {:cli, "mix ezagent user grant_cap --user <uri> --cap <json>"},
    "revoke" => {:cli, "mix ezagent user revoke_cap --user <uri> --cap <json>"},
    # agent_api_keys_live dispatches via Behavior.ApiKeys which Allen
    # 2026-05-26 FLIPPED from User Kind to Agent Kind. mix ezagent
    # auto-derives `put_api_key` / `delete_api_key` against `agent`.
    "put" => {:cli, "mix ezagent agent put_api_key --agent <uri> --provider <p> --key <k>"},
    "delete" => {:cli, "mix ezagent agent delete_api_key --agent <uri> --provider <p>"},

    # --- Feishu plugin ---
    "bind" => {:cli, "mix ezagent.feishu.bind <open-id> <user-uri>"},
    "unbind" => {:cli, "mix ezagent.feishu.unbind <open-id>"},
    # Generic ExternalMirror add_binding/unbind (admin/session_external_mirror_live)
    "add_binding" =>
      {:cli, "mix ezagent.external_mirror.bind <session-uri> <adapter-id> <target-id>"},
    # session_external_mirror_live also has an unbind clause — same
    # event name as the feishu one above; the LV files differ but the
    # event name is the same, and both have CLI counterparts. We don't
    # disambiguate by file in this invariant — the assertion is "this
    # event name has SOME CLI counterpart somewhere"; per-file
    # disambiguation is a finer-grain concern future PRs can layer on.

    # --- Snapshots ---
    "dump" => {:cli, "mix ezagent.snapshot.dump <uri>"},
    "clear" => {:cli, "mix ezagent.snapshot.clear <uri>"},

    # --- Settings (admin SMTP + email test) ---
    "save_smtp" =>
      {:deferred,
       "docs/futures/todo.md HIGH-3 — needs Behavior on App/SystemSettings Kind for :save_smtp_config; LV path uses Ezagent.AppSettings.put/2 directly"},
    "send_test_email" =>
      {:cli, "mix ezagent.auth.magic_link <email> (operator-debug mirror)"},

    # --- Agent extensions ---
    # The toggle event drives Behavior.Template.toggle_extension dispatch
    # in the cc plugin. mix ezagent auto-derives `mix ezagent template <action>`.
    "toggle" =>
      {:cli, "mix ezagent template toggle_extension --template <name> --id <ext-id> --enabled <bool>"},

    # --- Pure UI state (no mutation — exempt) ---
    "filter" => {:ui_only, "in-page text filter; no backend mutation"},
    "toggle_expand" => {:ui_only, "expand/collapse a UI row"},
    "toggle_mode" => {:ui_only, "form/json toggle in routing form"},
    "toggle_debug_panel" => {:ui_only, "show/hide a debug sidebar"},
    "switch_session" => {:ui_only, "chat-panel session navigation"},
    "switch_view" => {:ui_only, "chat/terminal view toggle"},
    "switch_to_pty_for_agent" => {:ui_only, "PTY agent picker"},
    "switch_tab" => {:ui_only, "observability tab switch"},
    "switch_section" => {:ui_only, "settings section nav"},
    "select_template_class" => {:ui_only, "workspace_detail template class picker"},
    "cmdk_open" => {:ui_only, "command palette open"},
    "cmdk_close" => {:ui_only, "command palette close"},
    "cmdk_query" => {:ui_only, "command palette filter"},
    "cmdk_select" => {:ui_only, "command palette item click → routes via push_navigate"},
    "edit_display_name" => {:ui_only, "begin inline edit; the mutation is in save_display_name"},
    "cancel_edit_display_name" => {:ui_only, "abort inline edit"},
    "open_invite_modal" => {:ui_only, "open invite UI"},
    "close_invite_modal" => {:ui_only, "close invite UI"},
    "close_dump" => {:ui_only, "close snapshot dump modal"},
    "preview" => {:ui_only, "preview computed shape; no persistence"},
    "validate_compose" => {:ui_only, "live form validation"},
    "cancel_upload" => {:ui_only, "cancel ongoing upload; LV-only state"},
    "mark_displayed" => {:ui_only, "client-side read tracking (Ezagent.Chat.ReadMarker.mark/4)"},
    "load_older_messages" => {:ui_only, "pagination — pure UI"},
    "update_test_recipient" => {:ui_only, "settings test-email recipient field"},
    "refresh" => {:ui_only, "force re-mount listings"},

    # --- PTY streaming ---
    "pty_input" => {:pty_stream, "real-time keystroke stream; CLI seeding via `mix ezagent agent write` exists but interactive use is impractical from one-shot mix tasks"},
    "pty_resize" => {:pty_stream, "real-time resize notification; ditto"}
  }

  test "every LV handle_event is categorized in @event_to_cli" do
    if not File.dir?(@lv_dir) do
      flunk(
        "LV directory not found at #{@lv_dir} — this invariant runs from " <>
          "the umbrella root via `mix test apps/ezagent_core/test/invariants/...`"
      )
    end

    lv_files = Path.wildcard(Path.join(@lv_dir, "**/*.ex"))
    events_in_lv = extract_events_from_lv(lv_files) |> Enum.uniq() |> Enum.sort()

    unmapped =
      Enum.reject(events_in_lv, &Map.has_key?(@event_to_cli, &1))

    assert unmapped == [],
           """
           LV/CLI parity gap (#{length(unmapped)} unmapped events):
             #{Enum.join(unmapped, ", ")}

           Each LV `handle_event(<name>, ...)` clause MUST have a row in
           `@event_to_cli` in this test. Add one of:
             {:cli, "mix ezagent <kind> <action> ..."}      — has a CLI counterpart
             {:ui_only, "<why no mutation>"}            — pure UI state
             {:pty_stream, "<why CLI is impractical>"}  — terminal streaming
             {:deferred, "<docs/futures/todo.md path>"} — explicit gap

           Per Allen 2026-05-25 (`feedback_completion_requires_invariant_test`):
           parity work isn't done until a regression test fails when
           the gap reopens. Adding a row is the gate.
           """
  end

  test "no @event_to_cli row references a stale LV event" do
    lv_files = Path.wildcard(Path.join(@lv_dir, "**/*.ex"))
    events_in_lv = extract_events_from_lv(lv_files) |> MapSet.new()
    mapped_events = Map.keys(@event_to_cli) |> MapSet.new()

    stale = MapSet.difference(mapped_events, events_in_lv) |> MapSet.to_list() |> Enum.sort()

    assert stale == [],
           """
           Stale @event_to_cli rows (#{length(stale)} events no longer in LV):
             #{Enum.join(stale, ", ")}

           Remove these rows — the LV clause was deleted. Keeping stale
           rows here hides future LV/CLI gaps because a stale row would
           silently satisfy a re-introduced event name with the wrong
           CLI mapping.
           """
  end

  test "category :deferred entries each cite docs/futures/todo.md" do
    # Per `feedback_dont_defer_what_is_solvable_now`: deferrals must be
    # justified + tracked, not invisible. Each :deferred row must
    # reference a docs/futures/todo.md (or docs/notes/...) bullet so
    # future PRs can find the work.
    bad =
      Enum.filter(@event_to_cli, fn
        {_, {:deferred, reason}} ->
          not (String.contains?(reason, "docs/futures/todo.md") or
                 String.contains?(reason, "docs/notes/"))

        _ ->
          false
      end)

    assert bad == [],
           """
           :deferred entries missing docs/futures/todo.md citation:
             #{inspect(bad)}

           Per `feedback_dont_defer_what_is_solvable_now`, every
           deferral cites the tracking bullet so a future PR can find
           and close it.
           """
  end

  test "summary: count by category" do
    by_cat =
      @event_to_cli
      |> Map.values()
      |> Enum.frequencies_by(fn {cat, _} -> cat end)

    # Sanity floor — if these get to zero, the test isn't doing its
    # job (someone deleted all events). The values themselves drift
    # naturally as features land/get retired; the test does NOT assert
    # exact numbers (that would be brittle).
    assert by_cat[:cli] > 10, "expected >10 CLI-covered events (have #{by_cat[:cli]})"
    assert by_cat[:ui_only] > 10, "expected >10 UI-only events (have #{by_cat[:ui_only]})"
    # Print for visibility on green runs (will show in `mix test` stdout
    # with --trace or verbose mode).
    IO.puts(
      "\nLV/CLI parity summary: #{inspect(by_cat)} " <>
        "(#{map_size(@event_to_cli)} total events tracked)"
    )
  end

  # --- helpers --------------------------------------------------------

  defp extract_events_from_lv(files) do
    Enum.flat_map(files, fn path ->
      content = File.read!(path)

      # Two patterns — single-line and multi-line `def handle_event`.
      # Single-line: `def handle_event("foo", ...`
      # Multi-line:  `def handle_event(\n        "foo",\n        ...`
      single_line =
        Regex.scan(~r/\bdef\s+handle_event\(\s*"([a-z_][a-z0-9_]*)"/, content)
        |> Enum.map(fn [_, name] -> name end)

      multi_line =
        Regex.scan(~r/\bdef\s+handle_event\(\s*\n\s*"([a-z_][a-z0-9_]*)"/, content)
        |> Enum.map(fn [_, name] -> name end)

      single_line ++ multi_line
    end)
  end
end

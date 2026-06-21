defmodule Ezagent.World.LvParityTest do
  @moduledoc """
  PR-0 parity gate for the LV→world migration (spec
  `docs/superpowers/specs/2026-06-21-world-lv-parity-migration-spec.md`).

  `ezagent_plugin_world` must absorb EVERY user-facing feature of
  `ezagent_plugin_liveview`, after which LV is retired (spec PR-7). The
  completion criterion is **parity with LV**, enumerated FROM LV — not a
  hand-listed page set (lesson: a hand list silently shrinks to whatever was
  enumerated; see `feedback_replacement_task_gate_is_parity_audit`).

  ## Why a feature-manifest RATCHET (not a handle_event-name diff)

  LV exposes one `handle_event/3` per feature; world exposes a single generic
  `"world:dispatch"` event carrying an `action` plus React components — different
  granularity, so a naive name-diff produces false positives/negatives. Instead
  this gate holds the authoritative LV feature inventory (extracted 2026-06-21,
  see `2026-06-21-world-lv-parity-INVENTORY.md`) and a `@pending_migration` set
  of features world does NOT yet reproduce. Each migration PR REMOVES the
  features it lands; the set MUST reach `[]` by PR-7. Adding an entry (or letting
  `@lv_*` shrink below the recorded baseline) fails the gate — forcing every LV
  feature to be explicitly claimed, which is exactly the check that was missing
  when world was first declared "done".

  Per-feature "world actually renders/dispatches it" is proven by each PR's
  agent-browser E2E, not statically here.
  """
  use ExUnit.Case, async: true

  # --- Authoritative LV inventory (extracted 2026-06-21) -------------------
  # 70 handle_event clauses across admin_live + admin/* + the *_live surfaces.
  @lv_events ~w(
    add_member add_rule bind cancel_edit_display_name cancel_upload chat_compose
    clear close_dump close_invite_modal cmdk_close cmdk_open cmdk_query cmdk_select
    create_agent create_session create_user create_workspace delete delete_rule
    disable_rule dump edit_display_name enable_rule filter grant grant_changed
    invite_member load_older_messages mark_displayed open_invite_modal preview
    promote_to_system pty_input pty_resize put refresh remove_member remove_template
    restart restart_orchestrator restart_pty revoke revoke_system
    routing_rule_add_session routing_rule_toggle save_display_name save_smtp
    select_template_class send_test_email set_default_source set_password
    switch_section switch_session switch_tab switch_to_pty_for_agent switch_view
    toggle toggle_debug_panel toggle_expand toggle_mode unbind update_test_recipient
    validate_compose
  )

  # 15 handle_info tags — the INBOUND realtime surface (codex C1).
  @lv_infos ~w(
    audit_event authz_event cc_connected cc_disconnected cc_event chat_message
    member_joined member_left member_offline member_presence notification
    pty_output pty_phase read_marker_updated slice_changed
  )

  # Recorded baselines — the gate fails if the inventory shrinks below these
  # (a silent LV surface drop) without an explicit edit here.
  @lv_events_baseline 63
  @lv_infos_baseline 15

  # --- Features world does NOT yet reproduce (the migration backlog) -------
  # RATCHET: each migration PR removes the features it lands. MUST be [] by PR-7.
  # Do NOT add entries. (world already covers: identities/agents/users/caps/
  # api-keys/extensions/new, PTY in/out/phase/resize, workspaces, plugins list,
  # feishu bindings, auto-derive list, profile, admin dashboard/observability/
  # registry/snapshots/templates/caps/authz-audit/settings/routing, sessions
  # list, agent create, cap grant/revoke, set_password, filter.)
  # PR-1 (session conversation core) landed + agent-browser-verified:
  #   chat_compose      — text-only send via `:session :send` dispatch.
  #                       @mention parsing + file attachments are PR-2 (the
  #                       ratchet can't see sub-feature completeness, so:
  #                       PR-1 chat_compose = TEXT ONLY).
  #   load_older_messages — backwards history paging (`MessageStore.older_than`).
  #   mark_displayed    — fire-and-forget read marker (once per message id).
  #   switch_session    — `?session=` deep-link via push_patch → handle_params.
  #   chat_message      — inbound bridge: session-topic broadcast → push_event.
  # Owed enrichment recorded in later-PR scope (the entry is gone from the
  # ratchet, so the reminder must live here + in the spec):
  #   - switch_session member-panel refresh → PR-3.
  #   - chat_compose @mention/upload → PR-2.
  # PR-3a (members panel) landed: the inbound membership/presence surface —
  # member_joined / member_left / member_offline / member_presence — now
  # re-reads the session members and pushes them to the React panel. invite/
  # remove (the WRITE side) is PR-3b.
  # PR-2b (file upload) landed: the React composer uploads via the cap-authed
  # `POST /world/uploads` → `:session :attach` chokepoint, holds pending
  # attachment chips, and sends signed grants on `chat.send`:
  #   validate_compose — client-side pre-flight (size/count) before POST.
  #   cancel_upload    — ✕ on a pending chip drops it (client-only).
  # PR-3b (session invite) landed: the members panel's Invite button opens an
  # entity-URI form (open_invite_modal / close_invite_modal = client modal
  # state) and submitting dispatches `:session :join` for the invited member
  # (invite_member). `remove_member` stays pending — in LV it is WORKSPACE member
  # removal (`workspace_detail_live`, `Ezagent.Workspace.remove_member`), a
  # workspace-surface feature, not the session panel.
  @pending_migration ~w(
    create_session switch_view switch_to_pty_for_agent
    remove_member
    restart_orchestrator routing_rule_add_session routing_rule_toggle
    toggle_debug_panel toggle_expand cmdk_open cmdk_close cmdk_query cmdk_select
    set_default_source save_smtp send_test_email update_test_recipient
    edit_display_name save_display_name cancel_edit_display_name
    bind unbind
    notification read_marker_updated cc_event cc_connected cc_disconnected
    slice_changed audit_event authz_event
  )

  @pending_baseline 30

  test "LV inventory has not silently shrunk below the recorded baseline" do
    assert length(@lv_events) >= @lv_events_baseline,
           "LV handle_event inventory shrank — re-extract and update baseline deliberately."

    assert length(@lv_infos) >= @lv_infos_baseline,
           "LV handle_info inventory shrank — re-extract and update baseline deliberately."
  end

  test "every pending-migration feature is a real LV feature (no phantom entries)" do
    inventory = MapSet.new(@lv_events ++ @lv_infos)
    pending = MapSet.new(@pending_migration)
    phantom = MapSet.difference(pending, inventory) |> MapSet.to_list()

    assert phantom == [],
           "pending_migration lists features not in the LV inventory: #{inspect(phantom)}"
  end

  test "pending-migration set only shrinks (ratchet toward LV retirement)" do
    assert length(@pending_migration) <= @pending_baseline,
           "pending_migration GREW (#{length(@pending_migration)} > #{@pending_baseline}). " <>
             "Migration PRs must REMOVE features as world absorbs them, never add. " <>
             "When this reaches 0, LV (spec PR-7) is retire-able."
  end
end

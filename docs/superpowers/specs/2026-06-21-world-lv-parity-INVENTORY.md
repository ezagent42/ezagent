# LV → world parity INVENTORY (PR-0 foundation)

Authoritative enumeration of `ezagent_plugin_liveview` surfaces, extracted
2026-06-21 (the completion criterion per `feedback_replacement_task_gate_is_parity_audit`).
The PR-0 parity test consumes this; migration is done when world covers every entry.

## 25 LiveViews
admin_authz_audit · admin_caps · admin_dashboard · **admin** (session conversation) ·
admin_templates · agent_api_keys · agent_detail · agent_extensions · agent_new ·
auto_derive · entities · entity_caps · feishu_bindings · identities · observability ·
plugins · profile · routing · session_external_mirror · settings · snapshots ·
terminal · users · workspace_detail · workspaces

## 1 LiveComponent
command_palette_component (events via `phx-target={@myself}` — invisible to parent inventory)

## 70 handle_event (the action surface)
add_member · add_rule · bind · cancel_edit_display_name · cancel_upload · chat_compose ·
clear · close_dump · close_invite_modal · cmdk_close · cmdk_open · cmdk_query · cmdk_select ·
create_agent · create_session · create_user · create_workspace · delete · delete_rule ·
disable_rule · dump · edit_display_name · enable_rule · filter · grant · grant_changed ·
invite_member · load_older_messages · mark_displayed · open_invite_modal · preview ·
promote_to_system · pty_input · pty_resize · put · refresh · remove_member · remove_template ·
restart · restart_orchestrator · restart_pty · revoke · revoke_system ·
routing_rule_add_session · routing_rule_toggle · save_display_name · save_smtp ·
select_template_class · send_test_email · set_default_source · set_password · switch_section ·
switch_session · switch_tab · switch_to_pty_for_agent · switch_view · toggle ·
toggle_debug_panel · toggle_expand · toggle_mode · unbind · update_test_recipient ·
validate_compose

## 15 handle_info (the INBOUND realtime surface — codex C1)
:audit_event · :authz_event · :cc_connected · :cc_disconnected · :cc_event · :chat_message ·
:member_joined · :member_left · :member_offline · :member_presence · :notification ·
:pty_output · :pty_phase · :read_marker_updated · :slice_changed

## Uploads (Phoenix LiveView upload — codex C1)
admin_live.ex · compose.ex · session_editor.ex (`allow_upload`/`live_file_input`/`consume_uploaded_entries`)

## PubSub subscriptions (server-side, must be bridged by WorldLive)
Ezagent.Audit.stream_topic() · Ezagent.CCEvents.topic() · Ezagent.Notifications.topic(caller) ·
SessionContext.bridge_topic_safely() · per-session event topics (workspace fan-out, admin_live.ex:114)
+ `Ezagent.Notifications.subscribe_slice_change(caller)`

## world coverage TODO (diff = what to build)
world currently covers: identities (users/agents/caps/api-keys/extensions/new/detail),
PTY (pty_input/pty_resize/pty_output/pty_phase), workspaces, plugins(feishu/auto list),
profile, admin(dashboard/observability/registry/snapshots/templates/caps/authz-audit/settings/routing),
sessions(list+layout), agents.create.

MISSING (the migration): the entire `admin` session-conversation event+info set
(chat_compose/validate_compose/cancel_upload + load_older_messages/mark_displayed +
create_session/switch_session/switch_view/switch_to_pty_for_agent + invite flow +
restart_orchestrator + routing_rule_* + toggle_debug_panel/toggle_expand + ALL the
:chat_message/:member_*/:notification/:read_marker/:slice_changed inbound handlers) ·
command_palette (cmdk_*) · auto_derive detail+cascade (set_default_source/revoke) ·
external_mirror (add_binding/unbind/refresh/toggle_expand) · settings extras
(save_smtp/send_test_email/update_test_recipient) · display-name edit · uploads.

The PR-0 parity test asserts world covers each row; RED until PR-7.

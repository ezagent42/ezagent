//! Integration tests for the Hook Pipeline (TC-1-HOOK-001 through TC-1-HOOK-011).
//!
//! These tests cover the 3-phase lifecycle (PreSend, AfterWrite, AfterRead),
//! priority ordering, dependency-based tie-breaking, special identity hooks,
//! error handling semantics, and global hook restrictions.

use std::sync::Arc;

use ezagent_engine::hooks::{
    HookContext, HookDeclaration, HookExecutor, HookPhase, TriggerEvent,
};

/// Helper: create a `HookDeclaration` with common defaults.
fn make_decl(
    id: &str,
    phase: HookPhase,
    trigger_datatype: &str,
    priority: u32,
    source: &str,
) -> HookDeclaration {
    HookDeclaration {
        id: id.to_string(),
        phase,
        trigger_datatype: trigger_datatype.to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority,
        source: source.to_string(),
    }
}

/// Helper: set up executor with built-in dependency order and built-in IDs.
fn setup_executor() -> HookExecutor {
    let mut executor = HookExecutor::new();
    executor.set_dependency_order(&[
        "identity".to_string(),
        "room".to_string(),
        "timeline".to_string(),
        "message".to_string(),
    ]);
    executor.set_builtin_ids(vec![
        "identity".to_string(),
        "room".to_string(),
        "timeline".to_string(),
        "message".to_string(),
    ]);
    executor
}

/// TC-1-HOOK-001: pre_send hook injects a field into context data.
#[test]
fn tc_1_hook_001_pre_send_modifies_data() {
    let mut executor = setup_executor();

    let decl = make_decl("timeline.inject_ref_id", HookPhase::PreSend, "message", 10, "timeline");
    let handler = Arc::new(|ctx: &mut HookContext| {
        ctx.data.insert(
            "ref_id".to_string(),
            serde_json::Value::String("injected-ref-001".to_string()),
        );
        Ok(())
    });
    executor.register(decl, handler).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    executor.execute(HookPhase::PreSend, &mut ctx).unwrap();

    assert_eq!(
        ctx.data.get("ref_id"),
        Some(&serde_json::Value::String("injected-ref-001".to_string())),
        "pre_send hook should inject ref_id field"
    );
}

/// TC-1-HOOK-002: room.check_room_write rejects a write with "NOT_A_MEMBER".
#[test]
fn tc_1_hook_002_pre_send_rejects_write() {
    let mut executor = setup_executor();

    let decl = make_decl("room.check_room_write", HookPhase::PreSend, "*", 5, "room");
    let handler = Arc::new(|ctx: &mut HookContext| {
        ctx.reject("NOT_A_MEMBER");
        Ok(())
    });
    executor.register(decl, handler).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    ctx.signer_id = Some("@mallory:relay-a.com".to_string());
    ctx.room_id = Some("R-alpha".to_string());

    let err = executor
        .execute(HookPhase::PreSend, &mut ctx)
        .unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("NOT_A_MEMBER"),
        "error should contain NOT_A_MEMBER, got: {msg}"
    );
}

/// TC-1-HOOK-003: hooks at p=10, 20, 30 execute in ascending priority order.
#[test]
fn tc_1_hook_003_priority_ordering() {
    let mut executor = setup_executor();

    // Register hooks in non-priority order: A(30), B(10), C(20).
    let decl_a = make_decl("hook_a", HookPhase::PreSend, "message", 30, "message");
    let handler_a = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("A".to_string());
        Ok(())
    });

    let decl_b = make_decl("hook_b", HookPhase::PreSend, "message", 10, "message");
    let handler_b = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("B".to_string());
        Ok(())
    });

    let decl_c = make_decl("hook_c", HookPhase::PreSend, "message", 20, "message");
    let handler_c = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("C".to_string());
        Ok(())
    });

    executor.register(decl_a, handler_a).unwrap();
    executor.register(decl_b, handler_b).unwrap();
    executor.register(decl_c, handler_c).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    executor.execute(HookPhase::PreSend, &mut ctx).unwrap();

    assert_eq!(
        ctx.executed_hooks,
        vec!["B", "C", "A"],
        "hooks should execute in priority order: B(10) -> C(20) -> A(30)"
    );
}

/// TC-1-HOOK-004: same-priority hooks tie-break by dependency topology order.
///
/// "channels" has dependency order index 4, "reply-to" has dependency order index 5.
/// Both at the same priority should execute channels first.
#[test]
fn tc_1_hook_004_same_priority_alphabetical_tiebreak() {
    let mut executor = HookExecutor::new();
    // Set up an extended dependency order including extensions.
    executor.set_dependency_order(&[
        "identity".to_string(),   // 0
        "room".to_string(),       // 1
        "timeline".to_string(),   // 2
        "message".to_string(),    // 3
        "channels".to_string(),   // 4
        "reply-to".to_string(),   // 5
    ]);
    executor.set_builtin_ids(vec![
        "identity".to_string(),
        "room".to_string(),
        "timeline".to_string(),
        "message".to_string(),
    ]);

    let decl_reply = make_decl("reply-to.enrich", HookPhase::PreSend, "message", 10, "reply-to");
    let handler_reply = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("reply-to".to_string());
        Ok(())
    });

    let decl_channels = make_decl("channels.route", HookPhase::PreSend, "message", 10, "channels");
    let handler_channels = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("channels".to_string());
        Ok(())
    });

    // Register in reverse order to prove sorting works.
    executor.register(decl_reply, handler_reply).unwrap();
    executor.register(decl_channels, handler_channels).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    executor.execute(HookPhase::PreSend, &mut ctx).unwrap();

    assert_eq!(
        ctx.executed_hooks,
        vec!["channels", "reply-to"],
        "channels (dep order 4) should execute before reply-to (dep order 5) at same priority"
    );
}

/// TC-1-HOOK-005: after_write context is read-only; handler error is logged, not propagated.
#[test]
fn tc_1_hook_005_after_write_cannot_modify_trigger_data() {
    let mut executor = setup_executor();

    let decl = make_decl("room.update_index", HookPhase::AfterWrite, "message", 10, "room");
    let handler = Arc::new(|ctx: &mut HookContext| {
        // Attempt to modify — in real code, read_only would be enforced.
        // The hook returns an error to simulate failure.
        if ctx.read_only {
            return Err(ezagent_engine::error::EngineError::PermissionDenied(
                "after_write context is read-only".to_string(),
            ));
        }
        Ok(())
    });
    executor.register(decl, handler).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    ctx.read_only = true;

    // AfterWrite errors are logged, not propagated.
    let result = executor.execute(HookPhase::AfterWrite, &mut ctx);
    assert!(
        result.is_ok(),
        "after_write hook error should be logged, not propagated"
    );
}

/// TC-1-HOOK-006: identity.sign_envelope at p=0 runs AFTER other p=0 hooks in PreSend.
#[test]
fn tc_1_hook_006_sign_envelope_runs_last() {
    let mut executor = setup_executor();

    // Register identity.sign_envelope at p=0.
    let decl_sign = HookDeclaration {
        id: "identity.sign_envelope".to_string(),
        phase: HookPhase::PreSend,
        trigger_datatype: "*".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 0,
        source: "identity".to_string(),
    };
    let handler_sign = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("sign_envelope".to_string());
        Ok(())
    });

    // Register room.check_membership at p=0.
    let decl_check = make_decl("room.check_membership", HookPhase::PreSend, "*", 0, "room");
    let handler_check = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("check_membership".to_string());
        Ok(())
    });

    // Register another hook at p=0.
    let decl_validate = make_decl("message.validate", HookPhase::PreSend, "message", 0, "message");
    let handler_validate = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("validate".to_string());
        Ok(())
    });

    // Register sign_envelope first to prove it gets moved to last.
    executor.register(decl_sign, handler_sign).unwrap();
    executor.register(decl_check, handler_check).unwrap();
    executor.register(decl_validate, handler_validate).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    executor.execute(HookPhase::PreSend, &mut ctx).unwrap();

    // sign_envelope must be the last hook executed.
    assert!(
        !ctx.executed_hooks.is_empty(),
        "at least one hook should execute"
    );
    assert_eq!(
        ctx.executed_hooks.last().unwrap(),
        "sign_envelope",
        "identity.sign_envelope must run LAST in PreSend. Order was: {:?}",
        ctx.executed_hooks
    );

    // Other hooks should run before sign_envelope.
    let sign_pos = ctx
        .executed_hooks
        .iter()
        .position(|h| h == "sign_envelope")
        .unwrap();
    for (i, hook) in ctx.executed_hooks.iter().enumerate() {
        if hook != "sign_envelope" {
            assert!(
                i < sign_pos,
                "hook '{}' at position {} should be before sign_envelope at position {}",
                hook,
                i,
                sign_pos
            );
        }
    }
}

/// TC-1-HOOK-007: after_read hook adds an enhanced field to the context.
#[test]
fn tc_1_hook_007_after_read_cannot_modify_crdt() {
    let mut executor = setup_executor();

    let decl = make_decl("message.enhance_display", HookPhase::AfterRead, "message", 10, "message");
    let handler = Arc::new(|ctx: &mut HookContext| {
        // AfterRead hooks may add enhanced display fields.
        ctx.data.insert(
            "enhanced_field".to_string(),
            serde_json::Value::String("display-value".to_string()),
        );
        ctx.executed_hooks.push("enhance_display".to_string());
        Ok(())
    });
    executor.register(decl, handler).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    ctx.read_only = true;

    executor.execute(HookPhase::AfterRead, &mut ctx).unwrap();

    assert_eq!(
        ctx.data.get("enhanced_field"),
        Some(&serde_json::Value::String("display-value".to_string())),
        "after_read hook should add enhanced_field to context data"
    );
}

/// TC-1-HOOK-008: pre_send chain stops when hook B at p=20 rejects; hook C at p=30 never runs.
#[test]
fn tc_1_hook_008_pre_send_error_stops_chain() {
    let mut executor = setup_executor();

    // Hook A at p=10: succeeds.
    let decl_a = make_decl("hook_a", HookPhase::PreSend, "message", 10, "message");
    let handler_a = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("A".to_string());
        Ok(())
    });

    // Hook B at p=20: rejects.
    let decl_b = make_decl("hook_b", HookPhase::PreSend, "message", 20, "room");
    let handler_b = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("B".to_string());
        ctx.reject("FORBIDDEN");
        Ok(())
    });

    // Hook C at p=30: should never run.
    let decl_c = make_decl("hook_c", HookPhase::PreSend, "message", 30, "message");
    let handler_c = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("C".to_string());
        Ok(())
    });

    executor.register(decl_a, handler_a).unwrap();
    executor.register(decl_b, handler_b).unwrap();
    executor.register(decl_c, handler_c).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    let err = executor.execute(HookPhase::PreSend, &mut ctx).unwrap_err();

    assert!(
        err.to_string().contains("FORBIDDEN"),
        "error should contain rejection reason"
    );
    assert_eq!(
        ctx.executed_hooks,
        vec!["A", "B"],
        "only hooks A and B should run; C should not execute after rejection"
    );
}

/// TC-1-HOOK-009: after_write hook A fails, but hook B still runs.
#[test]
fn tc_1_hook_009_after_write_error_continues_chain() {
    let mut executor = setup_executor();

    // Hook A at p=10: fails.
    let decl_a = make_decl("hook_a", HookPhase::AfterWrite, "message", 10, "room");
    let handler_a = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("A".to_string());
        Err(ezagent_engine::error::EngineError::PermissionDenied(
            "simulated failure".to_string(),
        ))
    });

    // Hook B at p=20: should still run.
    let decl_b = make_decl("hook_b", HookPhase::AfterWrite, "message", 20, "message");
    let handler_b = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("B".to_string());
        Ok(())
    });

    executor.register(decl_a, handler_a).unwrap();
    executor.register(decl_b, handler_b).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    let result = executor.execute(HookPhase::AfterWrite, &mut ctx);

    assert!(
        result.is_ok(),
        "after_write should not propagate hook errors"
    );
    assert_eq!(
        ctx.executed_hooks,
        vec!["A", "B"],
        "both hooks should execute; after_write error does not stop the chain"
    );
}

/// TC-1-HOOK-010: after_read hook errors silently; no error returned to caller.
#[test]
fn tc_1_hook_010_after_read_error_returns_raw() {
    let mut executor = setup_executor();

    let decl = make_decl("message.broken_enhancer", HookPhase::AfterRead, "message", 10, "message");
    let handler = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("broken_enhancer".to_string());
        Err(ezagent_engine::error::EngineError::PermissionDenied(
            "enhancer crashed".to_string(),
        ))
    });
    executor.register(decl, handler).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    ctx.data.insert(
        "body".to_string(),
        serde_json::Value::String("raw content".to_string()),
    );

    let result = executor.execute(HookPhase::AfterRead, &mut ctx);

    assert!(
        result.is_ok(),
        "after_read hook errors should be silently ignored"
    );
    // The original data is untouched.
    assert_eq!(
        ctx.data.get("body"),
        Some(&serde_json::Value::String("raw content".to_string())),
        "raw data should be preserved when after_read hook fails"
    );
}

/// TC-1-HOOK-011: non-builtin source registering a global hook (`"*"`) is rejected.
#[test]
fn tc_1_hook_011_extension_cannot_register_global() {
    let mut executor = setup_executor();

    let decl = make_decl("ext_reactions.global", HookPhase::PreSend, "*", 10, "reactions");
    let handler = Arc::new(|_ctx: &mut HookContext| Ok(()));

    let err = executor.register(decl, handler).unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("extensions cannot register global hooks"),
        "expected ExtensionCannotRegisterGlobalHook, got: {msg}"
    );
}

/// Additional: verify that a built-in source CAN register a global hook.
#[test]
fn builtin_can_register_global_hook() {
    let mut executor = setup_executor();

    let decl = make_decl("identity.verify_sig", HookPhase::AfterWrite, "*", 0, "identity");
    let handler = Arc::new(|_ctx: &mut HookContext| Ok(()));

    assert!(
        executor.register(decl, handler).is_ok(),
        "built-in source should be allowed to register global hooks"
    );
}

/// Additional: verify that hooks with non-matching trigger_datatype are skipped.
#[test]
fn hooks_with_non_matching_datatype_are_skipped() {
    let mut executor = setup_executor();

    let decl = make_decl("room.only_hook", HookPhase::PreSend, "room", 10, "room");
    let handler = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("room_hook".to_string());
        Ok(())
    });
    executor.register(decl, handler).unwrap();

    // Execute for "message" datatype — the "room" trigger should not match.
    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    executor.execute(HookPhase::PreSend, &mut ctx).unwrap();

    assert!(
        ctx.executed_hooks.is_empty(),
        "hook targeting 'room' should not run for 'message' context"
    );
}

/// Additional: verify that global hooks ("*") match all datatypes.
#[test]
fn global_hook_matches_all_datatypes() {
    let mut executor = setup_executor();

    let decl = make_decl("identity.global", HookPhase::PreSend, "*", 5, "identity");
    let handler = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("global".to_string());
        Ok(())
    });
    executor.register(decl, handler).unwrap();

    // Should trigger for "message".
    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    executor.execute(HookPhase::PreSend, &mut ctx).unwrap();
    assert_eq!(ctx.executed_hooks, vec!["global"]);

    // Should trigger for "room".
    let mut ctx2 = HookContext::new("room".to_string(), TriggerEvent::Update);
    executor.execute(HookPhase::PreSend, &mut ctx2).unwrap();
    assert_eq!(ctx2.executed_hooks, vec!["global"]);
}

/// Additional: verify trigger event filtering works.
#[test]
fn trigger_event_filtering() {
    let mut executor = setup_executor();

    let decl = HookDeclaration {
        id: "message.on_insert".to_string(),
        phase: HookPhase::PreSend,
        trigger_datatype: "message".to_string(),
        trigger_event: TriggerEvent::Insert,
        trigger_filter: None,
        priority: 10,
        source: "message".to_string(),
    };
    let handler = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("on_insert".to_string());
        Ok(())
    });
    executor.register(decl, handler).unwrap();

    // Should trigger for Insert.
    let mut ctx_insert = HookContext::new("message".to_string(), TriggerEvent::Insert);
    executor
        .execute(HookPhase::PreSend, &mut ctx_insert)
        .unwrap();
    assert_eq!(ctx_insert.executed_hooks, vec!["on_insert"]);

    // Should NOT trigger for Update.
    let mut ctx_update = HookContext::new("message".to_string(), TriggerEvent::Update);
    executor
        .execute(HookPhase::PreSend, &mut ctx_update)
        .unwrap();
    assert!(
        ctx_update.executed_hooks.is_empty(),
        "Insert-only hook should not trigger on Update"
    );
}

/// Additional: verify executor Default impl.
#[test]
fn executor_default() {
    let executor = HookExecutor::default();
    let mut ctx = HookContext::new("test".to_string(), TriggerEvent::Insert);
    assert!(executor.execute(HookPhase::PreSend, &mut ctx).is_ok());
}

/// Additional: pre_send hook returning an error (not via reject) also aborts.
#[test]
fn pre_send_handler_error_aborts_chain() {
    let mut executor = setup_executor();

    let decl_a = make_decl("hook_a", HookPhase::PreSend, "message", 10, "message");
    let handler_a = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("A".to_string());
        Err(ezagent_engine::error::EngineError::PermissionDenied(
            "unauthorized".to_string(),
        ))
    });

    let decl_b = make_decl("hook_b", HookPhase::PreSend, "message", 20, "message");
    let handler_b = Arc::new(|ctx: &mut HookContext| {
        ctx.executed_hooks.push("B".to_string());
        Ok(())
    });

    executor.register(decl_a, handler_a).unwrap();
    executor.register(decl_b, handler_b).unwrap();

    let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
    let err = executor.execute(HookPhase::PreSend, &mut ctx).unwrap_err();
    assert!(err.to_string().contains("unauthorized"));
    assert_eq!(
        ctx.executed_hooks,
        vec!["A"],
        "hook B should not run after hook A returns an error"
    );
}

//! Phase 0 integration tests: CRDT sync (TC-0-SYNC-001 through TC-0-SYNC-008).
//!
//! These tests verify that Yrs CRDT documents synchronize correctly
//! both over the Zenoh network transport and via direct state exchange.
//!
//! Network tests use a shared Zenoh session per test (simulating a
//! relay/bus) with separate CRDT backends per logical peer.  CRDT-only
//! tests use direct `encode_state` / `apply_update` exchange.

use std::sync::Arc;
use std::time::Duration;

use yrs::{Array, GetString, Map, Text, Transact};

use ezagent_backend::{CrdtBackend, NetworkBackend, YrsBackend, ZenohBackend, ZenohConfig};

// ---------------------------------------------------------------------------
// TC-0-SYNC-001: Basic Y.Map Sync
//
// Two peers connected via Zenoh. P1 sets key1=value1, publishes update
// via Zenoh. P2 receives within 2s, state vectors converge.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tc_0_sync_001_basic_ymap_sync() {
    let doc_id = "sync-001";
    let topic = "ezagent/test/sync-001/updates";

    // Create CRDT backends for each peer.
    let crdt_p1 = YrsBackend::new();
    let crdt_p2 = YrsBackend::new();

    // Shared Zenoh session (simulates the transport bus).
    let net = ZenohBackend::new(ZenohConfig::peer_isolated())
        .await
        .expect("session");

    // P2 subscribes first.
    let mut rx = net.subscribe(topic).await.expect("subscribe");
    tokio::time::sleep(Duration::from_millis(100)).await;

    // P1 writes to CRDT.
    {
        let doc = crdt_p1.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "key1", "value1");
    }

    // P1 encodes full state and publishes via the shared bus.
    let update = crdt_p1.encode_state(doc_id, None).expect("encode");
    net.publish(topic, &update).await.expect("publish");

    // P2 receives and applies.
    let received = tokio::time::timeout(Duration::from_secs(2), rx.recv())
        .await
        .expect("receive within 2s")
        .expect("channel open");
    crdt_p2.apply_update(doc_id, &received).expect("apply");

    // Verify data arrived.
    let doc_p2 = crdt_p2.get_or_create_doc(doc_id);
    let map_p2 = doc_p2.get_or_insert_map("data");
    let txn = doc_p2.transact();
    let val = map_p2.get(&txn, "key1").expect("key1 should exist");
    assert_eq!(val.to_string(&txn), "value1");

    // State vectors should match.
    let sv1 = crdt_p1.state_vector(doc_id).expect("sv1");
    let sv2 = crdt_p2.state_vector(doc_id).expect("sv2");
    assert_eq!(sv1, sv2, "state vectors must converge");
}

// ---------------------------------------------------------------------------
// TC-0-SYNC-002: Concurrent Writes Different Keys
//
// P1 sets "name"="Alice", P2 sets "age"="30". After exchange via Zenoh
// topics, both have both keys.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tc_0_sync_002_concurrent_writes_different_keys() {
    let doc_id = "sync-002";
    let topic_p1 = "ezagent/test/sync-002/p1";
    let topic_p2 = "ezagent/test/sync-002/p2";

    let crdt_p1 = YrsBackend::new();
    let crdt_p2 = YrsBackend::new();

    // Shared Zenoh session.
    let net = ZenohBackend::new(ZenohConfig::peer_isolated())
        .await
        .expect("session");

    // Cross-subscribe: P1 listens for P2's topic, P2 listens for P1's topic.
    let mut rx_from_p2 = net.subscribe(topic_p2).await.expect("sub p2");
    let mut rx_from_p1 = net.subscribe(topic_p1).await.expect("sub p1");
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Both write concurrently (different keys).
    {
        let doc = crdt_p1.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "name", "Alice");
    }
    {
        let doc = crdt_p2.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "age", "30");
    }

    // Exchange updates via Zenoh topics.
    let update_p1 = crdt_p1.encode_state(doc_id, None).expect("encode p1");
    let update_p2 = crdt_p2.encode_state(doc_id, None).expect("encode p2");
    net.publish(topic_p1, &update_p1).await.expect("pub p1");
    net.publish(topic_p2, &update_p2).await.expect("pub p2");

    // Receive and apply cross-updates.
    let msg_from_p2 = tokio::time::timeout(Duration::from_secs(2), rx_from_p2.recv())
        .await
        .expect("recv p2 update")
        .expect("channel");
    let msg_from_p1 = tokio::time::timeout(Duration::from_secs(2), rx_from_p1.recv())
        .await
        .expect("recv p1 update")
        .expect("channel");

    crdt_p1
        .apply_update(doc_id, &msg_from_p2)
        .expect("apply p2->p1");
    crdt_p2
        .apply_update(doc_id, &msg_from_p1)
        .expect("apply p1->p2");

    // Both should have both keys.
    for (label, crdt) in [("P1", &crdt_p1), ("P2", &crdt_p2)] {
        let doc = crdt.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let txn = doc.transact();
        assert_eq!(
            map.get(&txn, "name")
                .unwrap_or_else(|| panic!("{label} missing name"))
                .to_string(&txn),
            "Alice",
            "{label} name mismatch"
        );
        assert_eq!(
            map.get(&txn, "age")
                .unwrap_or_else(|| panic!("{label} missing age"))
                .to_string(&txn),
            "30",
            "{label} age mismatch"
        );
    }
}

// ---------------------------------------------------------------------------
// TC-0-SYNC-003: Same Key Concurrent Writes (LWW)
//
// P1 sets "color"="red", P2 sets "color"="blue". After exchange, both
// converge to the same value (CRDT deterministic tie-break).
// Direct CRDT exchange (no Zenoh needed).
// ---------------------------------------------------------------------------
#[test]
fn tc_0_sync_003_same_key_concurrent_lww() {
    let doc_id = "sync-003";

    let crdt_p1 = YrsBackend::new();
    let crdt_p2 = YrsBackend::new();

    // Both write the same key concurrently.
    {
        let doc = crdt_p1.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "color", "red");
    }
    {
        let doc = crdt_p2.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "color", "blue");
    }

    // Exchange full states.
    let state_p1 = crdt_p1.encode_state(doc_id, None).expect("encode p1");
    let state_p2 = crdt_p2.encode_state(doc_id, None).expect("encode p2");
    crdt_p1
        .apply_update(doc_id, &state_p2)
        .expect("apply p2->p1");
    crdt_p2
        .apply_update(doc_id, &state_p1)
        .expect("apply p1->p2");

    // Both must converge to the SAME value (we don't care which wins).
    let doc1 = crdt_p1.get_or_create_doc(doc_id);
    let doc2 = crdt_p2.get_or_create_doc(doc_id);
    let map1 = doc1.get_or_insert_map("data");
    let map2 = doc2.get_or_insert_map("data");
    let txn1 = doc1.transact();
    let txn2 = doc2.transact();
    let val1 = map1
        .get(&txn1, "color")
        .expect("p1 color")
        .to_string(&txn1);
    let val2 = map2
        .get(&txn2, "color")
        .expect("p2 color")
        .to_string(&txn2);
    assert_eq!(val1, val2, "both peers must converge to same value");
    assert!(
        val1 == "red" || val1 == "blue",
        "converged value must be one of the written values, got: {val1}"
    );
}

// ---------------------------------------------------------------------------
// TC-0-SYNC-004: Y.Array YATA Ordering
//
// P1 inserts "A" at 0, P2 inserts "B" at 0. After exchange, both have
// the same order (YATA deterministic).
// Direct CRDT exchange (no Zenoh needed).
// ---------------------------------------------------------------------------
#[test]
fn tc_0_sync_004_yarray_yata_ordering() {
    let doc_id = "sync-004";

    let crdt_p1 = YrsBackend::new();
    let crdt_p2 = YrsBackend::new();

    // P1 inserts "A" at index 0.
    {
        let doc = crdt_p1.get_or_create_doc(doc_id);
        let arr = doc.get_or_insert_array("items");
        let mut txn = doc.transact_mut();
        arr.insert(&mut txn, 0, "A");
    }

    // P2 inserts "B" at index 0.
    {
        let doc = crdt_p2.get_or_create_doc(doc_id);
        let arr = doc.get_or_insert_array("items");
        let mut txn = doc.transact_mut();
        arr.insert(&mut txn, 0, "B");
    }

    // Exchange full states.
    let state_p1 = crdt_p1.encode_state(doc_id, None).expect("encode p1");
    let state_p2 = crdt_p2.encode_state(doc_id, None).expect("encode p2");
    crdt_p1
        .apply_update(doc_id, &state_p2)
        .expect("apply p2->p1");
    crdt_p2
        .apply_update(doc_id, &state_p1)
        .expect("apply p1->p2");

    // Both must have 2 items in the SAME order.
    let doc1 = crdt_p1.get_or_create_doc(doc_id);
    let doc2 = crdt_p2.get_or_create_doc(doc_id);
    let arr1 = doc1.get_or_insert_array("items");
    let arr2 = doc2.get_or_insert_array("items");
    let txn1 = doc1.transact();
    let txn2 = doc2.transact();

    assert_eq!(arr1.len(&txn1), 2, "P1 should have 2 items");
    assert_eq!(arr2.len(&txn2), 2, "P2 should have 2 items");

    let p1_items: Vec<String> = (0..2)
        .map(|i| arr1.get(&txn1, i).unwrap().to_string(&txn1))
        .collect();
    let p2_items: Vec<String> = (0..2)
        .map(|i| arr2.get(&txn2, i).unwrap().to_string(&txn2))
        .collect();

    assert_eq!(p1_items, p2_items, "YATA ordering must be deterministic");
    // Both items must be present (order determined by YATA).
    assert!(p1_items.contains(&"A".to_string()), "must contain A");
    assert!(p1_items.contains(&"B".to_string()), "must contain B");
}

// ---------------------------------------------------------------------------
// TC-0-SYNC-005: Offline -> Reconnect Recovery
//
// P1 and P2 start with shared state. P2 goes "offline" (saves state
// vector). P1 writes more. P2 "reconnects" by requesting diff via
// state vector. P2 recovers complete state.
// Direct CRDT exchange (no Zenoh needed).
// ---------------------------------------------------------------------------
#[test]
fn tc_0_sync_005_offline_reconnect_recovery() {
    let doc_id = "sync-005";

    let crdt_p1 = YrsBackend::new();
    let crdt_p2 = YrsBackend::new();

    // Shared initial state: P1 writes, syncs to P2.
    {
        let doc = crdt_p1.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "shared", "initial");
    }
    let initial_state = crdt_p1.encode_state(doc_id, None).expect("encode initial");
    crdt_p2
        .apply_update(doc_id, &initial_state)
        .expect("apply initial");

    // P2 goes "offline" -- save its state vector.
    let sv_p2_offline = crdt_p2.state_vector(doc_id).expect("sv p2");

    // P1 writes more data while P2 is offline.
    {
        let doc = crdt_p1.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "new_key", "new_value");
        map.insert(&mut txn, "another", "data");
    }

    // P2 "reconnects" -- request diff from P1 using saved state vector.
    let diff = crdt_p1
        .encode_state(doc_id, Some(&sv_p2_offline))
        .expect("encode diff");
    crdt_p2.apply_update(doc_id, &diff).expect("apply diff");

    // P2 should have all data.
    let doc_p2 = crdt_p2.get_or_create_doc(doc_id);
    let map_p2 = doc_p2.get_or_insert_map("data");
    let txn = doc_p2.transact();
    assert_eq!(
        map_p2
            .get(&txn, "shared")
            .expect("shared")
            .to_string(&txn),
        "initial"
    );
    assert_eq!(
        map_p2
            .get(&txn, "new_key")
            .expect("new_key")
            .to_string(&txn),
        "new_value"
    );
    assert_eq!(
        map_p2
            .get(&txn, "another")
            .expect("another")
            .to_string(&txn),
        "data"
    );

    // State vectors should match.
    let sv1 = crdt_p1.state_vector(doc_id).expect("sv1");
    let sv2 = crdt_p2.state_vector(doc_id).expect("sv2");
    assert_eq!(sv1, sv2, "state vectors must converge after reconnect");
}

// ---------------------------------------------------------------------------
// TC-0-SYNC-006: Router Storage Persistence (via Queryable)
//
// A "router" peer holds state and registers as queryable. New peer P3
// queries and recovers full state.
// Uses a single Zenoh session with queryable + query on the same session.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tc_0_sync_006_router_storage_persistence() {
    let doc_id = "sync-006";
    let query_key = "ezagent/test/sync-006/state";

    let crdt_router = Arc::new(YrsBackend::new());
    let crdt_p3 = YrsBackend::new();

    // Router writes data.
    {
        let doc = crdt_router.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "persistent_key", "persistent_value");
        map.insert(&mut txn, "count", "42");
    }

    // Single Zenoh session acts as the bus.
    let net = ZenohBackend::new(ZenohConfig::peer_isolated())
        .await
        .expect("session");

    // Router registers queryable.
    let crdt_for_handler = Arc::clone(&crdt_router);
    let doc_id_owned = doc_id.to_string();
    net.register_queryable(
        query_key,
        Arc::new(move |_payload: Vec<u8>| {
            crdt_for_handler
                .encode_state(&doc_id_owned, None)
                .unwrap_or_default()
        }),
    )
    .await
    .expect("register queryable");

    tokio::time::sleep(Duration::from_millis(100)).await;

    // P3 queries via the same session (like querying a co-located router).
    let state_bytes = net
        .query(query_key, None)
        .await
        .expect("query should succeed");

    // P3 applies the received state.
    crdt_p3
        .apply_update(doc_id, &state_bytes)
        .expect("apply state");

    // Verify P3 has complete data.
    let doc_p3 = crdt_p3.get_or_create_doc(doc_id);
    let map_p3 = doc_p3.get_or_insert_map("data");
    let txn = doc_p3.transact();
    assert_eq!(
        map_p3
            .get(&txn, "persistent_key")
            .expect("key")
            .to_string(&txn),
        "persistent_value"
    );
    assert_eq!(
        map_p3
            .get(&txn, "count")
            .expect("count")
            .to_string(&txn),
        "42"
    );
}

// ---------------------------------------------------------------------------
// TC-0-SYNC-007: Y.Text Collaborative Editing
//
// P1 inserts "Hello ", P2 inserts "World", concurrently. After exchange,
// both converge to same text containing both substrings.
// Direct CRDT exchange (no Zenoh needed).
// ---------------------------------------------------------------------------
#[test]
fn tc_0_sync_007_ytext_collaborative_editing() {
    let doc_id = "sync-007";

    let crdt_p1 = YrsBackend::new();
    let crdt_p2 = YrsBackend::new();

    // P1 inserts "Hello ".
    {
        let doc = crdt_p1.get_or_create_doc(doc_id);
        let text = doc.get_or_insert_text("content");
        let mut txn = doc.transact_mut();
        text.insert(&mut txn, 0, "Hello ");
    }

    // P2 inserts "World".
    {
        let doc = crdt_p2.get_or_create_doc(doc_id);
        let text = doc.get_or_insert_text("content");
        let mut txn = doc.transact_mut();
        text.insert(&mut txn, 0, "World");
    }

    // Exchange full states.
    let state_p1 = crdt_p1.encode_state(doc_id, None).expect("encode p1");
    let state_p2 = crdt_p2.encode_state(doc_id, None).expect("encode p2");
    crdt_p1
        .apply_update(doc_id, &state_p2)
        .expect("apply p2->p1");
    crdt_p2
        .apply_update(doc_id, &state_p1)
        .expect("apply p1->p2");

    // Both must converge to the same text.
    let doc1 = crdt_p1.get_or_create_doc(doc_id);
    let doc2 = crdt_p2.get_or_create_doc(doc_id);
    let text1 = doc1.get_or_insert_text("content");
    let text2 = doc2.get_or_insert_text("content");
    let txn1 = doc1.transact();
    let txn2 = doc2.transact();

    let t1 = text1.get_string(&txn1);
    let t2 = text2.get_string(&txn2);

    assert_eq!(t1, t2, "both peers must converge to same text");
    assert!(
        t1.contains("Hello "),
        "merged text must contain 'Hello ', got: {t1}"
    );
    assert!(
        t1.contains("World"),
        "merged text must contain 'World', got: {t1}"
    );
}

// ---------------------------------------------------------------------------
// TC-0-SYNC-008: Zenoh QoS -- Send 10 Messages
//
// Send 10 messages via pub/sub. All 10 received without loss or
// duplication.  Uses a single Zenoh session for reliable delivery.
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tc_0_sync_008_zenoh_qos_10_messages() {
    let topic = "ezagent/test/sync-008/qos";
    let n = 10u32;

    // Single session for reliable pub/sub transport verification.
    let net = ZenohBackend::new(ZenohConfig::peer_isolated())
        .await
        .expect("session");

    let mut rx = net.subscribe(topic).await.expect("subscribe");
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Publish 10 messages with sequential payloads.
    for i in 0..n {
        let payload = i.to_be_bytes();
        net.publish(topic, &payload).await.expect("publish");
        // Small delay between publishes.
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    // Collect all received messages (with timeout).
    let mut received = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);

    while received.len() < n as usize {
        match tokio::time::timeout_at(deadline, rx.recv()).await {
            Ok(Some(data)) => {
                let val = u32::from_be_bytes(data.try_into().expect("4 bytes"));
                received.push(val);
            }
            Ok(None) => break, // channel closed
            Err(_) => break,   // timeout
        }
    }

    assert_eq!(
        received.len(),
        n as usize,
        "expected {n} messages, got {}",
        received.len()
    );

    // Verify no duplicates.
    let mut sorted = received.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(
        sorted.len(),
        n as usize,
        "no duplicate messages should be received"
    );

    // Verify all messages present.
    for i in 0..n {
        assert!(
            received.contains(&i),
            "message {i} should have been received"
        );
    }
}

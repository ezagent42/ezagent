//! Phase 0 integration tests: P2P networking (TC-0-P2P-001 through TC-0-P2P-003).
//!
//! These tests verify Zenoh peer-to-peer networking capabilities
//! including scouting, queryable, and router fallback.

use std::sync::Arc;
use std::time::Duration;

use yrs::{Map, Transact};

use ezagent_backend::{CrdtBackend, NetworkBackend, YrsBackend, ZenohBackend, ZenohConfig};

// ---------------------------------------------------------------------------
// TC-0-P2P-001: LAN Scouting / Peer Discovery
//
// Two peers discover each other via multicast scouting (peer mode,
// scouting enabled, no router). P1 publishes, P2 receives via the
// scouted peer link.
//
// NOTE: Multicast scouting requires a network environment that supports
// UDP multicast (224.0.0.224:7446). This is NOT available in most CI
// environments, containers, or restricted networks.
//
// This test is #[ignore]'d by default. Run explicitly with:
//   cargo test -- --ignored tc_0_p2p_001
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires multicast scouting — run: cargo test -- --ignored tc_0_p2p_001"]
async fn tc_0_p2p_001_lan_scouting() {
    let topic = "ezagent/test/p2p-001/scouting";

    // Both peers use default config with multicast scouting enabled.
    let net_p1 = ZenohBackend::new(ZenohConfig::peer_default())
        .await
        .expect("P1 session");
    let net_p2 = ZenohBackend::new(ZenohConfig::peer_default())
        .await
        .expect("P2 session");

    // P2 subscribes.
    let mut rx = net_p2.subscribe(topic).await.expect("subscribe");
    tokio::time::sleep(Duration::from_millis(500)).await; // Allow scouting time

    // P1 publishes a message.
    let payload = b"scouted-message";
    net_p1.publish(topic, payload).await.expect("publish");

    // P2 should receive via multicast-scouted peer link.
    let received = tokio::time::timeout(Duration::from_secs(3), rx.recv())
        .await
        .expect(
            "TC-0-P2P-001 FAILED: no message within 3s — \
             multicast scouting not available in this environment",
        )
        .expect("TC-0-P2P-001 FAILED: channel closed before message received");

    assert_eq!(received, payload.to_vec(), "scouted message mismatch");
    eprintln!("TC-0-P2P-001: multicast scouting verified");
}

// ---------------------------------------------------------------------------
// TC-0-P2P-002: Peer-as-Queryable
//
// P1 holds 5 key-value pairs in a CRDT doc and registers as queryable.
// P3 queries and recovers all 5 pairs.
// Uses a single session (queryable + query on same bus).
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tc_0_p2p_002_peer_as_queryable() {
    let doc_id = "p2p-002";
    let query_key = "ezagent/test/p2p-002/state";

    let crdt_p1 = Arc::new(YrsBackend::new());
    let crdt_p3 = YrsBackend::new();

    // P1 writes 5 key-value pairs.
    {
        let doc = crdt_p1.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, "k1", "v1");
        map.insert(&mut txn, "k2", "v2");
        map.insert(&mut txn, "k3", "v3");
        map.insert(&mut txn, "k4", "v4");
        map.insert(&mut txn, "k5", "v5");
    }

    // Single Zenoh session.
    let net = ZenohBackend::new(ZenohConfig::peer_isolated())
        .await
        .expect("session");

    // P1 registers as queryable.
    let crdt_for_handler = Arc::clone(&crdt_p1);
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

    // P3 queries.
    let state_bytes = net
        .query(query_key, None)
        .await
        .expect("query should succeed");

    crdt_p3
        .apply_update(doc_id, &state_bytes)
        .expect("apply state");

    // Verify P3 has all 5 pairs.
    let doc_p3 = crdt_p3.get_or_create_doc(doc_id);
    let map_p3 = doc_p3.get_or_insert_map("data");
    let txn = doc_p3.transact();
    for i in 1..=5 {
        let key = format!("k{i}");
        let expected = format!("v{i}");
        let actual = map_p3
            .get(&txn, &key)
            .unwrap_or_else(|| panic!("missing {key}"))
            .to_string(&txn);
        assert_eq!(actual, expected, "{key} mismatch");
    }

    // State vectors must converge (spec: P3 sv == P1 sv).
    let sv_p1 = crdt_p1.state_vector(doc_id).expect("sv p1");
    let sv_p3 = crdt_p3.state_vector(doc_id).expect("sv p3");
    assert_eq!(sv_p1, sv_p3, "state vectors must converge after query recovery");
}

// ---------------------------------------------------------------------------
// TC-0-P2P-003: Relay Fallback
//
// Both peers connect to router at tcp/127.0.0.1:7447. P1 publishes,
// P2 receives via router. Requires zenohd running locally.
//
// This test is #[ignore]'d by default. Run explicitly with:
//   zenohd -l tcp/0.0.0.0:7447 &
//   cargo test -- --ignored tc_0_p2p_003
// ---------------------------------------------------------------------------
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires zenohd router — run: zenohd -l tcp/0.0.0.0:7447 &"]
async fn tc_0_p2p_003_relay_fallback() {
    let router_endpoint = "tcp/127.0.0.1:7447";

    let net_p1 = ZenohBackend::new(ZenohConfig::peer_with_router(router_endpoint))
        .await
        .unwrap_or_else(|e| {
            panic!(
                "TC-0-P2P-003 FAILED: cannot connect to zenohd at {router_endpoint}: {e}\n\
                 → Start router first: zenohd -l tcp/0.0.0.0:7447 &"
            )
        });

    let net_p2 = ZenohBackend::new(ZenohConfig::peer_with_router(router_endpoint))
        .await
        .unwrap_or_else(|e| {
            panic!(
                "TC-0-P2P-003 FAILED: cannot connect P2 to zenohd at {router_endpoint}: {e}"
            )
        });

    let topic = "ezagent/test/p2p-003/relay";

    let mut rx = net_p2.subscribe(topic).await.expect("subscribe");
    tokio::time::sleep(Duration::from_millis(300)).await;

    let payload = b"relayed-message";
    net_p1.publish(topic, payload).await.expect("publish");

    let received = tokio::time::timeout(Duration::from_secs(3), rx.recv())
        .await
        .expect(
            "TC-0-P2P-003 FAILED: no message within 3s — \
             zenohd may not be routing correctly",
        )
        .expect("TC-0-P2P-003 FAILED: channel closed before message received");

    assert_eq!(received, payload.to_vec(), "relayed message mismatch");
    eprintln!("TC-0-P2P-003: relay fallback verified via {router_endpoint}");
}

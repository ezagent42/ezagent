#!/usr/bin/env node
//
// Phase 6 PR 15 — Feishu WS long-connect sidecar for esr-ng.
//
// Why a Node sidecar instead of native Elixir WS:
//   The lark long-connect protocol (handshake / heartbeat / event
//   framing / dedup) is encapsulated in `@larksuiteoapi/node-sdk` and
//   not publicly documented. Re-implementing in Elixir is 300-600 LOC
//   of reverse-engineering risk. The sidecar is ~80 LOC of glue.
//
// Wire format with Ezagent:
//   stdin   = (unused for now; future Ezagent→sidecar commands)
//   stdout  = one JSON line per event:
//     {"type":"event","schema":"2.0","header":{...},"event":{...}}
//     {"type":"connected"}
//     {"type":"disconnected","reason":"..."}
//     {"type":"error","message":"..."}
//
// Credentials come via env vars (Ezagent sets them when spawning):
//   FEISHU_APP_ID
//   FEISHU_APP_SECRET
//   FEISHU_DOMAIN    (default "https://open.feishu.cn", set
//                     "https://open.larksuite.com" for lark.com tenants)

const lark = require('@larksuiteoapi/node-sdk');

const APP_ID = process.env.FEISHU_APP_ID;
const APP_SECRET = process.env.FEISHU_APP_SECRET;
const DOMAIN = process.env.FEISHU_DOMAIN || lark.Domain.Feishu;

function emit(obj) {
    try {
        process.stdout.write(JSON.stringify(obj) + '\n');
    } catch (err) {
        // EPIPE: Ezagent side closed the pipe (e.g. code reload restarted
        // the WsClient GenServer). Exit cleanly so the Elixir
        // supervisor respawns us with a fresh Port.
        if (err && err.code === 'EPIPE') {
            process.exit(0);
        }
        throw err;
    }
}

// SDK logger writes to stdout directly; if Elixir pipe is gone,
// those writes throw async. Catch at the process level too.
process.on('uncaughtException', (err) => {
    if (err && err.code === 'EPIPE') {
        process.exit(0);
    }
    throw err;
});

function fatal(msg) {
    emit({ type: 'error', message: msg });
    process.exit(1);
}

if (!APP_ID || !APP_SECRET) {
    fatal('FEISHU_APP_ID and FEISHU_APP_SECRET env vars are required');
}

// Forward every lark event to Ezagent as a JSON line. Ezagent's Elixir-side
// Port reader parses one line at a time.
const eventDispatcher = new lark.EventDispatcher({}).register({
    'im.message.receive_v1': async (data) => {
        // SDK strips schema/header wrapping; re-wrap so Ezagent's existing
        // build_message_body code reads the same shape it did from
        // HTTP webhook events.
        emit({
            type: 'event',
            schema: '2.0',
            header: { event_type: 'im.message.receive_v1' },
            event: data,
        });
    },
    'im.message.reaction.created_v1': async (data) => {
        emit({
            type: 'event',
            schema: '2.0',
            header: { event_type: 'im.message.reaction.created_v1' },
            event: data,
        });
    },
});

const wsClient = new lark.WSClient({
    appId: APP_ID,
    appSecret: APP_SECRET,
    domain: DOMAIN,
    loggerLevel: lark.LoggerLevel.warn,
});

emit({ type: 'sidecar_starting' });

wsClient
    .start({ eventDispatcher })
    .then(() => emit({ type: 'connected' }))
    .catch((err) => {
        emit({ type: 'error', message: String(err && err.message ? err.message : err) });
        process.exit(1);
    });

process.on('SIGINT', () => {
    emit({ type: 'disconnected', reason: 'sigint' });
    try { wsClient.close({ force: true }); } catch (_) {}
    process.exit(0);
});

process.on('SIGTERM', () => {
    emit({ type: 'disconnected', reason: 'sigterm' });
    try { wsClient.close({ force: true }); } catch (_) {}
    process.exit(0);
});

// Phase 7 PR 35 — orphan reap via stdin EOF.
//
// When the Elixir parent (Ezagent.PluginFeishu.WsClient via Port.open) exits,
// the OS reaps the Port but does NOT propagate a signal to this Node
// child — `:spawn_executable` Ports leak their children to PID 1 on
// BEAM crash/exit. Without explicit handling, every phx.server restart
// leaves a new orphan sidecar (we hit this in Phase 6 PR 27 debug —
// 3 orphans accumulated across the day, all racing for Feishu events,
// stealing inbound messages, silently dropping).
//
// The fix is universal across BEAM ports: child reads its own stdin and
// exits when it sees EOF. The Elixir Port closes stdin on Port.close /
// VM exit, so this fires reliably on parent death. SIGINT/SIGTERM
// handlers stay as primary signal paths; this is a belt-and-suspenders
// safety net for the case where the parent dies without sending a
// signal.
// Phase 7 PR 35 — orphan reap via parent PID check (replaces stdin EOF).
//
// `process.stdin.resume()` conflicts with the Lark SDK's internal WSS event
// loop — in flowing mode, Node.js starves WebSocket message processing and no
// `im.message.receive_v1` events are delivered (bisect-3 confirmed, 2026-06-26).
//
// Instead, check every 5s whether the parent (Elixir BEAM) is still alive. When
// the parent dies, this child is re-parented to PID 1 (or a subreaper); we
// detect that and exit cleanly so the WsClient GenServer can respawn us.
const PARENT_PID = process.ppid;
const orphanCheck = setInterval(() => {
    if (process.ppid !== PARENT_PID || process.ppid === 1) {
        emit({ type: 'disconnected', reason: 'parent_exited' });
        try { wsClient.close({ force: true }); } catch (_) {}
        clearInterval(orphanCheck);
        process.exit(0);
    }
}, 5_000);

// Keep the process alive (the SDK manages its own WS loop).
setInterval(() => {}, 60_000);

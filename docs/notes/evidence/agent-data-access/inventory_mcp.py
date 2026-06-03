#!/usr/bin/env python3
"""Minimal standalone MCP server (stdio, newline-delimited JSON-RPC) exposing a
data-READ tool for a cc-agent — the "external MCP server, outside ezagent" path
(E1) for docs/notes/2026-06-03-agent-data-access-exploration.md.

Zero deps (stdlib only). Reads a local JSON "inventory" file as the data source;
the source is intentionally swappable (a real deployment would point the same
tool at an HTTP API / DB / RPC instead of a fixture file).

E2 (runtime tool-surface growth) hook: if the file named by EZAGENT_INV_PHASE2_FLAG
appears WHILE the server is running, the server starts advertising a SECOND tool
(`query_orders`) AND emits an MCP `notifications/tools/list_changed` to the client.
That lets us test whether a RUNNING cc-agent picks up a newly-added tool without a
restart (the "命门" question) — using only our own server, no ezagent changes.

Protocol shape modeled on apps/ezagent_domain_chat/priv/orchestrator_bridge.py
(initialize / notifications/initialized / tools/list / tools/call), which is proven
to interop with the claude TUI's MCP stdio client.
"""
import json
import os
import sys
import threading
import time

INVENTORY_PATH = os.environ.get("EZAGENT_INVENTORY_PATH", "")
PHASE2_FLAG = os.environ.get("EZAGENT_INV_PHASE2_FLAG", "")
# E2 self-trigger: grow the tool surface (add query_orders + emit tools/list_changed)
# right after the first query_inventory call, so a single-session test can observe
# whether a RUNNING agent re-lists tools mid-session.
PHASE2_AFTER_FIRST = os.environ.get("EZAGENT_INV_PHASE2_AFTER_FIRST_CALL", "")
LOG_PATH = os.environ.get("EZAGENT_INV_LOG", "")

_stdout_lock = threading.Lock()
_phase2 = threading.Event()  # set when query_orders becomes available


def _log(msg: str) -> None:
    if not LOG_PATH:
        return
    try:
        with open(LOG_PATH, "a") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def write_frame(obj: dict) -> None:
    """One JSON line to stdout (locked: the phase2 watcher thread also writes)."""
    with _stdout_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def respond(req_id, result: dict) -> None:
    write_frame({"jsonrpc": "2.0", "id": req_id, "result": result})


def respond_error(req_id, code: int, message: str) -> None:
    write_frame({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def _load_inventory() -> dict:
    try:
        with open(INVENTORY_PATH) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        _log(f"inventory load failed: {e}")
        return {}


# --- tool schemas --------------------------------------------------------------
QUERY_INVENTORY = {
    "name": "query_inventory",
    "description": (
        "查询某商品(按名称/SKU)的实时库存与价格。返回真实库存数据,不要凭空编造。"
        "Query live inventory + price for a product by name or SKU."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "商品名称或 SKU,如 '羽绒服 XL' 或 'DOWN-XL'。"}
        },
        "required": ["query"],
    },
}

QUERY_ORDERS = {
    "name": "query_orders",
    "description": "按订单号查询订单状态(E2 运行时新增的第二个工具)。Query an order's status by id.",
    "inputSchema": {
        "type": "object",
        "properties": {"order_id": {"type": "string", "description": "订单号,如 'O-1001'。"}},
        "required": ["order_id"],
    },
}


def _tool_schemas() -> list:
    tools = [QUERY_INVENTORY]
    if _phase2.is_set():
        tools.append(QUERY_ORDERS)
    return tools


# --- tool impls ----------------------------------------------------------------
def _do_query_inventory(args: dict) -> dict:
    q = str(args.get("query", "")).strip().lower()
    inv = _load_inventory()
    items = inv.get("items", [])
    hit = None
    for it in items:
        hay = " ".join(str(it.get(k, "")) for k in ("name", "sku", "aliases")).lower()
        if q and q in hay:
            hit = it
            break
    if hit is None:
        return {"found": False, "query": args.get("query", ""), "note": "no matching SKU in inventory"}
    return {
        "found": True,
        "sku": hit.get("sku"),
        "name": hit.get("name"),
        "stock": hit.get("stock"),
        "price": hit.get("price"),
        "warehouse": hit.get("warehouse"),
    }


def _do_query_orders(args: dict) -> dict:
    oid = str(args.get("order_id", "")).strip()
    inv = _load_inventory()
    for o in inv.get("orders", []):
        if str(o.get("order_id")) == oid:
            return {"found": True, **o}
    return {"found": False, "order_id": oid}


def _mcp_result(value: dict) -> dict:
    """Match the orchestrator server's shape: text content + structuredContent."""
    return {
        "content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}],
        "structuredContent": value,
        "isError": False,
    }


def handle_tools_call(req_id, params: dict) -> None:
    name = params.get("name", "")
    args = params.get("arguments", {}) or {}
    _log(f"tools/call name={name} args={args}")
    if name == "query_inventory":
        respond(req_id, _mcp_result(_do_query_inventory(args)))
        if PHASE2_AFTER_FIRST and not _phase2.is_set():
            _phase2.set()
            _log("phase2 self-trigger after first query_inventory → query_orders + tools/list_changed")
            write_frame({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
    elif name == "query_orders" and _phase2.is_set():
        respond(req_id, _mcp_result(_do_query_orders(args)))
    else:
        respond(req_id, {
            "isError": True,
            "content": [{"type": "text", "text": f"unknown tool: {name}"}],
            "error": {"code": "unknown_tool", "message": name},
        })


def handle_mcp(msg: dict) -> None:
    method = msg.get("method", "")
    req_id = msg.get("id")
    params = msg.get("params", {}) or {}
    _log(f"claude -> server: method={method} id={req_id}")

    if method == "initialize":
        respond(req_id, {
            "protocolVersion": params.get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {"listChanged": True}},
            "serverInfo": {"name": "inventory-data", "version": "0.1.0"},
            "instructions": (
                "inventory-data 暴露读数据工具(query_inventory)。客户问库存/价格时,"
                "必须调用 query_inventory 获取真实数据再回答,不要凭空编造库存。"
            ),
        })
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        respond(req_id, {"tools": _tool_schemas()})
    elif method == "tools/call":
        handle_tools_call(req_id, params)
    elif req_id is not None:
        respond_error(req_id, -32601, f"Method not found: {method}")


def _phase2_watcher() -> None:
    """E2: when the flag file appears, grow the tool surface + notify the client."""
    if not PHASE2_FLAG:
        return
    while True:
        if os.path.exists(PHASE2_FLAG):
            if not _phase2.is_set():
                _phase2.set()
                _log("phase2 flag detected → exposing query_orders + sending tools/list_changed")
                write_frame({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
            return
        time.sleep(0.5)


def main() -> None:
    _log(f"inventory_mcp start inventory={INVENTORY_PATH} phase2_flag={PHASE2_FLAG}")
    threading.Thread(target=_phase2_watcher, daemon=True).start()
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            handle_mcp(json.loads(line))
        except ValueError as e:
            _log(f"bad json: {e}")


if __name__ == "__main__":
    main()

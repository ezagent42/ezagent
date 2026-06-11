"""
Cinnox plugin — MCP tool implementations.

Provides customer lookup, billing, subscription, and permission
check tools backed by autoservice.mock_db.MockDB.
"""

import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional

from autoservice.mock_db import MockDB
from autoservice.permission import check_permission

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# KB resources (lazy-loaded on first kb_search call, cached process-wide)
# ---------------------------------------------------------------------------

_KB_GLOSSARY: dict | None = None
_KB_SYNONYMS: dict | None = None


def _kb_load() -> tuple[dict, dict]:
    """Load glossary + synonym map from plugin references. Cached."""
    global _KB_GLOSSARY, _KB_SYNONYMS
    if _KB_GLOSSARY is None or _KB_SYNONYMS is None:
        base = Path(__file__).parent / "references"
        try:
            _KB_GLOSSARY = json.loads(
                (base / "glossary.json").read_text(encoding="utf-8"),
            )
        except Exception as exc:
            log.warning("cinnox kb_search: glossary load failed: %s", exc)
            _KB_GLOSSARY = {}
        try:
            _KB_SYNONYMS = json.loads(
                (base / "synonym-map.json").read_text(encoding="utf-8"),
            )
        except Exception as exc:
            log.warning("cinnox kb_search: synonym load failed: %s", exc)
            _KB_SYNONYMS = {}
    return _KB_GLOSSARY, _KB_SYNONYMS


# Escalation keywords are loaded from a sibling JSON file shared with the
# framework KB MCP server (autoservice/kb_mcp_server.py). Single source of
# truth — Feishu (via this plugin tool) and voice/web (via the framework
# tool) read the SAME list, so a keyword change in one channel never
# silently leaves another channel unprotected.
#
# Keep the list TIGHT in the JSON file. Adding non-numeric terms (e.g.
# plain "DID") would wrongly skip glossary lookup for legitimate
# term-definition questions.
_ESCALATION_KEYWORDS_PATH = (
    Path(__file__).parent / "kb_escalation_keywords.json"
)
_ESCALATION_KEYWORDS_CACHE: list[str] | None = None


def _load_escalation_keywords() -> list[str]:
    """Load this plugin's escalation keyword list. Lazy + cached.

    Returns ``[]`` (no short-circuit) when the JSON file is missing or
    malformed — preserves legacy behavior of falling through to glossary
    search.
    """
    global _ESCALATION_KEYWORDS_CACHE
    if _ESCALATION_KEYWORDS_CACHE is not None:
        return _ESCALATION_KEYWORDS_CACHE
    keywords: list[str] = []
    try:
        if _ESCALATION_KEYWORDS_PATH.is_file():
            data = json.loads(
                _ESCALATION_KEYWORDS_PATH.read_text(encoding="utf-8"),
            )
            if isinstance(data, list):
                keywords = [str(k) for k in data]
            elif isinstance(data, dict):
                raw = data.get("keywords") or []
                if isinstance(raw, list):
                    keywords = [str(k) for k in raw]
    except Exception:
        log.warning(
            "cinnox kb_search: failed to load %s",
            _ESCALATION_KEYWORDS_PATH, exc_info=True,
        )
    _ESCALATION_KEYWORDS_CACHE = keywords
    return keywords


def _detect_escalation(query_lower: str) -> str | None:
    """Return the first matched escalation keyword, or None."""
    for kw in _load_escalation_keywords():
        if kw in query_lower:
            return kw
    return None


# The plugin loader injects the DB instance at load time.
# Tools receive it via the plugin's db attribute during dispatch.
# For standalone usage, callers must set _db before calling.
_db: Optional[MockDB] = None


def _get_db() -> MockDB:
    if _db is None:
        raise RuntimeError("MockDB not initialized — call set_db() first")
    return _db


def set_db(db: MockDB) -> None:
    """Set the shared MockDB instance for all tools."""
    global _db
    _db = db


def _envelope(data=None, error=None) -> dict:
    """Wrap response in standard API envelope."""
    return {
        "success": error is None,
        "data": data,
        "error": error,
        "timestamp": datetime.now().isoformat(),
        "mode": "mock",
    }


# --------------------------------------------------------------------------
# MCP Tools
# --------------------------------------------------------------------------

def customer_lookup(identifier: str) -> dict:
    """Look up a CINNOX customer by account ID, phone, or company name."""
    db = _get_db()
    customer = db.get_customer(identifier)
    if not customer:
        return _envelope(error=f"Customer not found: {identifier}")
    db.log_api_call(f"/api/cinnox/customers/{identifier}", "GET", response=customer)
    return _envelope(data=customer)


def billing_query(account_id: str, start_date: str = None, end_date: str = None) -> dict:
    """Get customer billing history and invoice status."""
    db = _get_db()
    customer = db.get_customer(account_id)
    if not customer:
        return _envelope(error=f"Customer not found: {account_id}")
    actual_id = customer["id"]
    result = db.get_billing(actual_id, start_date, end_date)
    db.log_api_call(f"/api/cinnox/customers/{account_id}/billing", "GET", response=result)
    return _envelope(data=result)


def subscription_query(account_id: str) -> dict:
    """Get active subscriptions and DID numbers."""
    db = _get_db()
    customer = db.get_customer(account_id)
    if not customer:
        return _envelope(error=f"Customer not found: {account_id}")
    actual_id = customer["id"]
    subs = db.get_subscriptions(actual_id)
    result = {"subscriptions": subs}
    db.log_api_call(f"/api/cinnox/customers/{account_id}/subscriptions", "GET", response=result)
    return _envelope(data=result)


def kb_search(query: str, limit: int = 5) -> dict:
    """Search the CINNOX knowledge base (glossary + synonym map).

    Used by the customer agent when soul rule "只用 KB 回答" applies and
    a question touches CINNOX product / pricing / feature terms. The
    glossary covers ~350 product terms (DID, IVR, IDD, PSTN, SSO/AD,
    Omnichannel, …). Pricing tables are NOT in this KB — for套餐/价格
    queries the tool returns empty matches, signalling the agent to
    escalate per the soul's "KB 没明确写的数字 → 不说具体数" rule.

    Args:
        query: Free-text search term in any case, possibly using the
               synonym map (e.g. "did" expands to "DID (Direct Inward
               Dialing)" → glossary lookup).
        limit: Max matches to return (default 5).

    Returns:
        Envelope with {"matches": [{"term", "description", "related",
        "score"}, ...], "query_normalized": str}.
    """
    glossary, synonyms = _kb_load()
    q_raw = (query or "").strip()
    if not q_raw:
        return _envelope(data={"matches": [], "query_normalized": ""})

    q_lower = q_raw.lower()

    # Hard short-circuit: pricing / plan-tier / SLA / contract queries.
    # The KB does not carry these numbers, and the voice soul mandates
    # immediate escalation (rule "反幻觉(语音场景): KB 没明确写的数字 →
    # 不说具体数"). Returning a structured signal here lets the agent
    # skip the full glossary scan AND the "should I try another tool"
    # reasoning loop — go straight to the escalation phrase.
    escalate_kw = _detect_escalation(q_lower)
    if escalate_kw:
        log.info(
            "cinnox kb_search: escalation triggered by keyword %r in query %r",
            escalate_kw, q_raw,
        )
        return _envelope(data={
            "matches": [],
            "match_count": 0,
            "query_normalized": q_raw,
            "escalate_required": True,
            "escalate_reason": "pricing_or_sla_not_in_kb",
            "escalate_keyword": escalate_kw,
        })

    # Synonym expansion: if the query matches a known alias, use the
    # canonical term as an additional search needle alongside the raw query.
    canonical = synonyms.get(q_lower)
    needles = [q_lower]
    if canonical and canonical.lower() not in needles:
        needles.append(canonical.lower())

    matches = []
    for term, entry in glossary.items():
        term_lower = term.lower()
        desc_lower = (entry.get("description") or "").lower()
        score = 0
        for needle in needles:
            if needle == term_lower:
                score += 100   # exact term hit
            elif needle in term_lower:
                score += 30    # substring in term
            elif needle in desc_lower:
                score += 10    # substring in description
        if score > 0:
            matches.append({
                "term": term,
                "description": entry.get("description", ""),
                "related": entry.get("related", []),
                "score": score,
            })

    matches.sort(key=lambda m: m["score"], reverse=True)
    matches = matches[:max(1, int(limit))]
    return _envelope(data={
        "matches": matches,
        "query_normalized": canonical or q_raw,
        "match_count": len(matches),
    })


def permission_check(action: str, product_id: str = None) -> dict:
    """Check if an action is permitted for the current operator."""
    db = _get_db()

    # Get product-specific permissions from DB if a product_id is given
    product_permissions = None
    if product_id:
        product_data = db.get_product_full_data(product_id)
        if product_data:
            product_permissions = product_data.get("operator_permissions")

    result = check_permission(
        action=action,
        product_permissions=product_permissions,
        domain="customer-service",
    )
    response = {
        "action": result.action,
        "level": result.level.value,
        "allowed": result.allowed,
        "reason": result.reason,
        "workflow": result.workflow,
        "display": result.to_display_block(),
    }
    db.log_api_call("/api/cinnox/permissions/check", "POST",
                    params={"action": action, "product_id": product_id},
                    response=response)
    return _envelope(data=response)

# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.2"]
# ///
"""cinnox KB search — stdio MCP tool over kb.db.

Uses AutoService's REAL retrieval, not invented logic:
  * `query_expansion.expand_query` — CJK→English bilingual expansion so a
    Chinese query hits the English KB (copied verbatim from AutoService).
  * `_tokenize_fts_query` — the trigram-aware FTS5 tokenizer (verbatim from
    AutoService dream_agent.py).
  * the same FTS SQL: `kb_fts MATCH ? AND kb_type='product_knowledge'
    ORDER BY rank`.

A genuine miss returns "no results" (the soul then escalates) — it does
NOT dump the whole KB.
"""
import os
import re
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from query_expansion import expand_query  # noqa: E402  (AutoService, verbatim)

from mcp.server.fastmcp import FastMCP  # noqa: E402

DB = os.environ.get(
    "KB_DB_PATH", "/home/huangjiajia/.ezagent/default/cc-agents/cinnox/kb.db"
)
mcp = FastMCP("cinnox-kb")

# Verbatim from AutoService dream_agent._FTS_SPLIT_RE: FTS5 metachars +
# ASCII/CJK punctuation + whitespace as token separators.
_FTS_SPLIT_RE = re.compile(r'["\(\)\*:\^，。；！？、：“”‘’「」『』\s,.;!?]+')


def _tokenize_fts_query(query: str) -> str:
    """Verbatim from AutoService dream_agent._tokenize_fts_query (trigram)."""
    fragments = [f for f in _FTS_SPLIT_RE.split(query) if len(f) >= 2]
    if not fragments:
        return ""
    terms: list[str] = []
    seen: set[str] = set()

    def _add(term: str) -> None:
        if term and term not in seen:
            seen.add(term)
            terms.append(term)

    for frag in fragments:
        _add(frag)
        if len(frag) > 4:
            for i in range(len(frag) - 2):
                _add(frag[i : i + 3])
    return " OR ".join(f'"{term}"' for term in terms)


@mcp.tool()
def kb_search(query: str, top_k: int = 5) -> str:
    """Search the CINNOX product knowledge base.

    Returns the most relevant product / feature / pricing / value-
    proposition snippets for `query` (FTS over the cinnox KB, ranked).
    Call this to ground answers about CINNOX / M800 products and services.
    Returns "no results" when the KB does not cover the query.
    """
    if not query or not query.strip():
        return "No results (empty query)."
    fts = _tokenize_fts_query(expand_query(query))
    if not fts.strip():
        return "No results."
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    try:
        try:
            rows = conn.execute(
                "SELECT c.content, c.source_name, c.section FROM kb_fts f "
                "JOIN kb_chunks c ON c.rowid = f.rowid "
                "WHERE kb_fts MATCH ? AND c.kb_type = 'product_knowledge' "
                "ORDER BY rank LIMIT ?",
                (fts, max(int(top_k), 1)),
            ).fetchall()
        except sqlite3.Error:
            rows = []
        if not rows:
            return (
                "No results — the KB does not cover this query. "
                "Recap what the customer needs and hand off to a human agent."
            )
        parts = []
        for r in rows:
            tag = r["source_name"] or "CINNOX product"
            sec = f" · {r['section']}" if r["section"] else ""
            parts.append(f"[{tag}{sec}]\n{r['content'].strip()}")
        return "\n\n---\n\n".join(parts)
    finally:
        conn.close()


if __name__ == "__main__":
    mcp.run()

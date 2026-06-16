#!/usr/bin/env python3
"""Minimal KB search MCP script — JSON-file-based, no MCP server required.

CLI modes:
  --db-path PATH  --query TEXT       → search (returns JSON array)
  --db-path PATH  --upsert JSON      → upsert entry
  --db-path PATH  --delete ID        → delete entry
  --db-path PATH  --rebuild          → rebuild kb.json from _sources + glossary.json
                     --glossary PATH
                     --sources PATH
Stores entries as kb_entries.json (a JSON array of objects).
"""

import argparse, json, os, sys, hashlib, re, html as html_mod, sqlite3
from pathlib import Path


def _load_entries(db_dir: str) -> list:
    p = Path(db_dir) / "kb_entries.json"
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            return []
    return []


def _save_entries(db_dir: str, entries: list):
    p = Path(db_dir) / "kb_entries.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")


# ── FTS5 helpers (trigram tokenizer for CJK support) ──

def _get_fts_conn(db_dir: str):
    """Open FTS connection. Returns (conn, tokenizer) or (None, None) if unavailable."""
    db_path = str(Path(db_dir) / "kb_fts.db")
    try:
        conn = sqlite3.connect(db_path)
        # Try trigram tokenizer first (best for CJK), then unicode61, then give up
        for tok in ["trigram", "unicode61"]:
            try:
                conn.execute(
                    f"CREATE VIRTUAL TABLE IF NOT EXISTS kb_fts "
                    f"USING fts5(id, title, content, tokenize='{tok}')"
                )
                conn.commit()
                return conn, tok
            except sqlite3.OperationalError:
                continue
        conn.close()
        return None, None
    except Exception:
        return None, None


def _fts_upsert(conn, entry: dict):
    """Insert or replace an entry in the FTS index."""
    eid = entry.get("id", "")
    title = entry.get("title", "") or ""
    content = entry.get("content", "") or ""
    try:
        conn.execute(
            "INSERT OR REPLACE INTO kb_fts(rowid, id, title, content) "
            "VALUES ((SELECT rowid FROM kb_fts WHERE id=?), ?, ?, ?)",
            (eid, eid, str(title), str(content)),
        )
        conn.commit()
    except Exception:
        pass


def _fts_delete(conn, entry_id: str):
    """Delete an entry from the FTS index."""
    try:
        conn.execute("DELETE FROM kb_fts WHERE id=?", (entry_id,))
        conn.commit()
    except Exception:
        pass


def _fts_search(conn, query: str, limit: int = 20) -> list:
    """Search FTS5 and return matching entry IDs in score order."""
    tokens = query.strip().split()
    if not tokens:
        return []
    safe_terms = " AND ".join(
        '"' + t.replace('"', '""') + '"' for t in tokens if t
    )
    try:
        rows = conn.execute(
            f"SELECT id FROM kb_fts WHERE kb_fts MATCH ? ORDER BY rank LIMIT ?",
            (safe_terms, limit),
        ).fetchall()
        return [r[0] for r in rows]
    except Exception:
        return []


def _fts_rebuild_conn(db_dir: str):
    """Drop and recreate FTS table, return (conn, tokenizer)."""
    db_path = str(Path(db_dir) / "kb_fts.db")
    try:
        conn = sqlite3.connect(db_path)
        conn.execute("DROP TABLE IF EXISTS kb_fts")
        conn.commit()
    except Exception:
        return None, None
    return _get_fts_conn(db_dir)


def cmd_search(args):
    entries = _load_entries(args.db_path)
    query = (args.query or "").strip()
    if not query:
        return entries[:20]

    # Try FTS5 search first (trigram tokenizer for CJK support)
    conn, tokenizer = _get_fts_conn(args.db_path)
    if conn:
        try:
            matched_ids = _fts_search(conn, query)
            if matched_ids:
                conn.close()
                id_set = set(matched_ids)
                id_order = {eid: i for i, eid in enumerate(matched_ids)}
                results = [e for e in entries if e.get("id") in id_set]
                results.sort(key=lambda e: id_order.get(e.get("id"), 999))
                return results[:20]
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # Fallback: substring match with scoring
    q_lower = query.lower()
    scored = []
    for e in entries:
        title = (e.get("title", "") or "").lower()
        content = (e.get("content", "") or "").lower()
        score = 0
        if q_lower in title:
            score += 10
        if q_lower in content:
            score += 1
        if score > 0:
            scored.append((score, e))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [e for _, e in scored[:20]]


def cmd_upsert(args):
    entry = json.loads(args.upsert)
    entries = _load_entries(args.db_path)
    eid = entry.get("id")
    found = False
    for i, e in enumerate(entries):
        if e.get("id") == eid:
            entries[i] = entry
            found = True
            break
    if not found:
        entries.append(entry)
    _save_entries(args.db_path, entries)
    # Index into FTS5
    conn, _ = _get_fts_conn(args.db_path)
    if conn:
        try:
            _fts_upsert(conn, entry)
        finally:
            conn.close()


def cmd_delete(args):
    entries = _load_entries(args.db_path)
    entries = [e for e in entries if e.get("id") != args.delete]
    _save_entries(args.db_path, entries)
    # Remove from FTS5
    conn, _ = _get_fts_conn(args.db_path)
    if conn:
        try:
            _fts_delete(conn, args.delete)
        finally:
            conn.close()


def _plain_text_from_html(html: str) -> str:
    """Strip HTML tags, decode entities, keep CJK text."""
    text = re.sub(r"<script[^>]*>.*?</script>", "", html, flags=re.S | re.I)
    text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html_mod.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def cmd_rebuild(args):
    """Rebuild kb_entries.json from _sources directory and glossary.json."""
    db_dir = Path(args.db_path)
    entries = []

    # Process URL sources
    sources_dir = Path(args.sources) if args.sources else db_dir / "_sources"
    url_dir = sources_dir / "url"
    if url_dir.exists():
        for f in sorted(url_dir.glob("*.html")):
            try:
                html = f.read_text(encoding="utf-8")
                text = _plain_text_from_html(html)
                if len(text) > 100:
                    entries.append({
                        "id": f"url:{f.stem[:12]}",
                        "title": f"URL Source: {f.stem[:20]}",
                        "content": text[:5000],
                        "source_type": "url",
                        "source_id": f.stem
                    })
            except Exception:
                pass

    # Process file sources
    files_dir = sources_dir / "files"
    if files_dir.exists():
        for f in sorted(files_dir.iterdir()):
            if f.is_file() and f.suffix in (".txt", ".md", ".pdf", ".docx"):
                try:
                    text = f.read_text(encoding="utf-8")[:5000]
                    entries.append({
                        "id": f"file:{f.stem[:12]}",
                        "title": f"File: {f.name}",
                        "content": text,
                        "source_type": "file",
                        "source_id": f.stem
                    })
                except Exception:
                    pass

    # Process glossary
    glossary_path = Path(args.glossary) if args.glossary else db_dir / "glossary.json"
    if glossary_path.exists():
        try:
            glossary = json.loads(glossary_path.read_text(encoding="utf-8"))
            for item in glossary[:200]:
                entries.append({
                    "id": f"glossary:{item.get('term', '')[:20]}",
                    "title": item.get("term", ""),
                    "content": item.get("definition", ""),
                    "source_type": "glossary"
                })
        except Exception:
            pass

    # Also keep manually added entries (those without source_type)
    existing = [e for e in _load_entries(str(db_dir)) if not e.get("source_type")]
    all_entries = existing + entries
    _save_entries(str(db_dir), all_entries)
    # Rebuild FTS5 index
    conn, tokenizer = _fts_rebuild_conn(str(db_dir))
    if conn:
        try:
            for e in all_entries:
                _fts_upsert(conn, e)
            tokenizer_info = f" (tokenizer: {tokenizer})" if tokenizer else ""
            print(
                f"Rebuilt: {len(all_entries)} entries "
                f"({len(existing)} manual + {len(entries)} sourced)"
                f"{tokenizer_info}"
            )
        finally:
            conn.close()
    else:
        print(f"Rebuilt: {len(all_entries)} entries ({len(existing)} manual + {len(entries)} sourced)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db-path", required=True)
    parser.add_argument("--query")
    parser.add_argument("--upsert")
    parser.add_argument("--delete")
    parser.add_argument("--rebuild", action="store_true")
    parser.add_argument("--glossary")
    parser.add_argument("--sources")
    args = parser.parse_args()

    if args.query is not None:
        results = cmd_search(args)
        print(json.dumps(results, ensure_ascii=False))
    elif args.upsert is not None:
        cmd_upsert(args)
    elif args.delete is not None:
        cmd_delete(args)
    elif args.rebuild:
        cmd_rebuild(args)
    else:
        print("[]")


if __name__ == "__main__":
    main()

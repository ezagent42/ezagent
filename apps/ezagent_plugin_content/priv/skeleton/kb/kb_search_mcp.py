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

import argparse, json, os, sys, hashlib, re, html as html_mod
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


def cmd_search(args):
    entries = _load_entries(args.db_path)
    query = args.query.lower().strip()
    if not query:
        return entries[:20]
    # Simple substring match with scoring
    scored = []
    for e in entries:
        title = (e.get("title", "") or "").lower()
        content = (e.get("content", "") or "").lower()
        score = 0
        if query in title:
            score += 10
        if query in content:
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


def cmd_delete(args):
    entries = _load_entries(args.db_path)
    entries = [e for e in entries if e.get("id") != args.delete]
    _save_entries(args.db_path, entries)


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

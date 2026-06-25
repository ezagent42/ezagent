# `docs/board.md` format — markmap tree + on-ezagent node model

The off board is ONE `docs/board.md`. It is a **markmap mindmap** (so `markmap` /
XMind / the live board's `import_markmap` read the tree) carrying **the same node
model the live on-ezagent board uses** — same field names, same status values,
same artifact link shape — so **off and on are usage-identical**.

## Tree = markmap headings (the live board's exact format)
Each node is a markdown heading; `#` depth = tree depth (`#`=root, `##`=child…).
The heading text is the node `title` and nothing else. This is byte-for-byte the
`EzagentPluginKanban.Markmap` format (`markmap.ex`): the first heading must be a
single `#` (root), no depth jumps (`#` then `###` = malformed), deterministic DFS.
`markmap` / XMind / the live `import_markmap` open it as a mindmap.

**Depth note:** a full `positioning`→…→`pr` relay path nests 9 levels deep
(`#########`), past Markdown's usual 6-level `######` cap. That is fine here —
`markmap.ex` and `scripts/validate_skill.sh` count leading `#` characters, not HTML
heading levels — so don't be surprised by 7+ `#`. (Surfaced by the skill-creator
eval, 2026-06-25.)

## Node metadata = mirror of the on-ezagent node (markmap ignores these lines)
markmap parses ONLY `#` headings; every other line is ignored. So per-node
metadata lives in **blockquote lines** under each heading. Fields mirror the live
node (`kanban.ex` moduledoc §15-19) **exactly** — same names, same legal values:

```markdown
# 定位稿
> stage: positioning · owner: alice@acme · status: doing
> artifact: tool=github kind=pr ref=#42 url=https://github.com/o/r/pull/42
> artifact: tool=feishu kind=doc url=https://feishu.cn/docx/xxxx
> metric: name=7天阅读 target=500 current=320 unit=次

## 北极星指标
> stage: metric · owner: — · status: unassigned
```

- **stage** ∈ `positioning | metric | pain | anchor | ux | feature | issue | test | pr` (the 9-stage chain).
- **owner** = a user id/uri, or `—` when unclaimed.
- **status** ∈ `unassigned | claimed | doing | done` — the live board's coarse
  4-state; **fine status lives in the linked tool**, exactly as on-ezagent.
- **artifact** (0+) = `tool` · `kind` · `ref` · `url` (+ optional inline
  `content:`) — the live `%{tool,kind,ref,url,content}` shape for GitHub PRs /
  feishu docs / xmind / code files. **The `url` is the same link the live board
  stores** — a contributor following it lands in the same place on or off.
- **metric** (0+) = `name` · `target` · `current` · `unit` — the live
  `%{name,target,current,unit}` shape.

A blockquote line that markmap-renders as noise is fine: viewers show the tree
(headings); the blockquotes are machine/teammate metadata.

## Validation (two layers — the SAME the on board enforces)
A `board.md` is valid iff:
1. **Tree** — the `#` headings, extracted, parse as a valid markmap tree (first is
   a single `#` root; no depth jumps). This is `EzagentPluginKanban.Markmap.parse`
   applied to the heading lines.
2. **Stage relay** — each child node's `stage` is its **parent's stage OR the next
   stage** in the 9-chain — never a skip or a step back (the live `stage_fits?`,
   `kanban.ex:413-438`, "相邻棒推进"). The root is `positioning`.
3. **Fields** — every node's `status` ∈ the 4 values; each `artifact`/`metric`
   line has the required keys.

`scripts/new_board.sh` scaffolds a valid `positioning` root; the board check in
`scripts/validate_skill.sh` enforces 1–3 — so the off board never drifts from a
shape the live board could `import_markmap` and accept.

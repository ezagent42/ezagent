# Done — append-only log

<!--
Working memory, gitignored. APPEND ONLY — never rewrite or delete entries.
Each completed unit of work gets one entry: what, commit sha (if any), when.
Single actor (the common first case): just append to the flat list below — no
`## @<actor-id>` heading needed. Multi-actor shared tree: put your entries under
your own `## @<actor-id>` heading and never touch anyone else's.
-->

- [<YYYY-MM-DD HH:MM>] <what was finished> — <commit sha or "no commit">
- [<YYYY-MM-DD HH:MM>] <what was finished> — <commit sha or "no commit">

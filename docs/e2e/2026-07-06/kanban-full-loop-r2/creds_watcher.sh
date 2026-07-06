#!/usr/bin/env bash
# 手动 creds 过渡方式(S6 精神,A²落地前):watch 新 materialize 的 cc agent config dir,
# 抢在 claude 启动读 creds 前把宿主 ~/.claude/.credentials.json 拷进去。
# 只处理本 run 新建的 dir(启动后出现的),不碰旧 dir。
set -u
BASE=~/.ezagent/default/cc-agents/system
SRC=~/.claude/.credentials.json
MARKER=$(mktemp)
LOG="${1:-/tmp/creds_watcher.log}"
DEADLINE=$(( $(date +%s) + ${2:-180} ))
echo "watcher start $(date +%T.%N)" > "$LOG"
declare -A SEEN
# 预登记已存在的 dir
for d in "$BASE"/*/; do [ -d "$d" ] && SEEN["$d"]=1; done
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  for d in "$BASE"/*/; do
    [ -d "$d" ] || continue
    if [ -z "${SEEN[$d]:-}" ]; then
      SEEN["$d"]=1
      if [ ! -f "$d/.credentials.json" ]; then
        cp "$SRC" "$d/.credentials.json" && chmod 600 "$d/.credentials.json"
        echo "copied -> $d at $(date +%T.%N)" >> "$LOG"
      fi
    fi
  done
  sleep 0.05
done
echo "watcher end $(date +%T.%N)" >> "$LOG"
rm -f "$MARKER"

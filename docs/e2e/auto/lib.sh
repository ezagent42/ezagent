#!/usr/bin/env bash
# docs/e2e/auto/lib.sh — agent-browser E2E 自动化共享库
# 规范见 ../guide.md §8。被 run.sh source。所有交互坑(native-setter / requestSubmit /
# @mention 真键盘 autocomplete / data-last-dispatch)都封装在这里,2026-06-26 实地验证。

set -uo pipefail

BASE_URL="${BASE_URL:-http://world.localhost:10042}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@ezagent.chat}"
ADMIN_PW="${ADMIN_PW:-worlddev}"
EVID_DIR="${EVID_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/evidence}"

PASS=0 FAIL=0 SKIP=0
declare -a FAILED_LINES=()

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
info(){ printf '   %s\n' "$*"; }
pass(){ PASS=$((PASS+1)); c_g "  ✅ PASS: $*"; }
fail(){ FAIL=$((FAIL+1)); FAILED_LINES+=("$*"); c_r "  🟥 FAIL: $*"; }
skip(){ SKIP=$((SKIP+1)); c_y "  ⏭️  SKIP: $*"; }
step(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

# --- agent-browser 原子封装 ---
AB(){ agent-browser "$@" 2>&1 | tail -1; }
ab_open(){ agent-browser open "$1" >/dev/null 2>&1; }
ab_wait(){ agent-browser wait "$1" >/dev/null 2>&1; }      # selector 或 ms
ab_click(){ agent-browser click "$1" >/dev/null 2>&1; }
ab_key(){ agent-browser keyboard type "$1" >/dev/null 2>&1; }
ab_press(){ agent-browser press "$1" >/dev/null 2>&1; }
ab_eval(){ # 返回 JS 值;agent-browser 把字符串 JSON 化(带引号)→ 去掉外层引号便于比较
  local r; r=$(agent-browser eval "$1" 2>&1 | tail -1); r="${r%\"}"; r="${r#\"}"; printf '%s' "$r"; }
ab_shot(){ agent-browser screenshot "$1" >/dev/null 2>&1; }
ab_close(){ agent-browser close --all >/dev/null 2>&1; }

# --- 浏览器获取模式(dev/host vs 容器内部署)---
# HOST(dev,默认):宿主上跑 run.sh 时 E2E_BROWSER_CDP 未设(compose 的 env 不会传到宿主)
#   → 后续 `agent-browser open` 自起本机 Chrome(沿用旧路径,完全不变)。
# 容器内(deploy):ezagent 容器把 E2E_BROWSER_CDP 设到 sidecar → 这里 `connect` 一次,之后
#   所有 ab_open/ab_click/ab_eval/ab_shot 复用这条已连接的 CDP 会话(connect 经守护进程 +
#   unix socket 跨多次独立 CLI 调用持久化,2026-06-27 实测验证)。镜像里**没有本机 Chrome**
#   (Chrome 只在 sidecar),所以容器内没有 open-本机 的回退路径:CDP 设了却连不上 = 配置错
#   (多半是没带 --profile e2e 起 chromium,或 token 不符),必须**硬失败**而非 fail-open
#   到注定失败的 `agent-browser open`(codex r-review #2/#3 / let-it-crash)。
# URL 的 `?` 前需带 `/`(browserless v2 对 `ws://h:3000?token=` 返回 400;正确是 `ws://h:3000/?token=`)。
ab_connect_bootstrap(){
  [ -n "${E2E_BROWSER_CDP:-}" ] || return 0      # HOST/dev:不连远端,留给 open 自起本机 Chrome
  # 关键坑(2026-06-27 实测):compose 用 `${ESR_PROXY:-}` 给容器注入了**空字符串**的
  # HTTP_PROXY/HTTPS_PROXY 等。agent-browser 的 CDP 客户端把空串当成非法 proxy → connect
  # 直接放弃远端、回退去起本机 Chrome("Chrome not found")。把**值为空**的 proxy 变量
  # unset 掉(只删空的,真有代理时不动),connect 才能正常贴到 sidecar。函数内 unset 会作用到
  # source 它的 run.sh 外层 shell,后续所有 ab_*(独立进程)都继承这份干净环境。
  local v
  for v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy; do
    if [ -n "${!v+x}" ] && [ -z "${!v}" ]; then unset "$v"; fi
  done
  local i
  for i in 1 2 3 4 5 6; do                        # sidecar 可能仍在预热 → 重试
    if agent-browser connect "$E2E_BROWSER_CDP" >/dev/null 2>&1; then
      info "agent-browser connected to CDP sidecar"; return 0
    fi
    sleep 3
  done
  c_r "agent-browser connect 失败:$E2E_BROWSER_CDP — 容器内 E2E 需 --profile e2e 起 chromium sidecar(且 BROWSERLESS_TOKEN 一致)"
  exit 1                                           # 硬失败:容器内无本机 Chrome 可回退
}
ab_connect_bootstrap

# React 受控字段填值(native-setter + 派发事件)。val 不可含单引号(URI/名都安全)。
ab_fill_react(){ # selector value
  ab_eval "(()=>{const el=document.querySelector('$1');if(!el)return 'ERR:no-el';const p=el.tagName==='SELECT'?window.HTMLSelectElement.prototype:window.HTMLInputElement.prototype;Object.getOwnPropertyDescriptor(p,'value').set.call(el,'$2');el.dispatchEvent(new Event(el.tagName==='SELECT'?'change':'input',{bubbles:true}));return 'OK';})()"
}
# React 岛 form 提交(requestSubmit,见 §8.2)
ab_submit(){ # form selector
  ab_eval "(()=>{const f=document.querySelector('$1');if(!f)return 'ERR:no-form';const b=f.querySelector('button[type=submit]');f.requestSubmit?f.requestSubmit(b):b.click();return 'OK';})()"
}
# 读 #world-root 的 data-last-dispatch(提交结果信号)
ab_dispatch(){ ab_eval "(()=>document.querySelector('#world-root')?.getAttribute('data-last-dispatch'))()"; }

# --- 登录 ---
ab_login(){
  ab_open "$BASE_URL/login"
  agent-browser fill '#email' "$ADMIN_EMAIL" >/dev/null 2>&1
  agent-browser fill '#password' "$ADMIN_PW" >/dev/null 2>&1
  ab_click 'button[type="submit"]'
  ab_wait '[data-world-component=sessions_table]'
}

# --- @mention 真键盘 autocomplete 发送(关键:不能 native-setter 硬塞)---
ab_mention_send(){ # type_query(如 e2e-c) tail_text
  ab_click 'textarea[aria-label="Message"]'
  ab_key "@$1"
  ab_wait 1000
  ab_click 'ul[role="listbox"] button'   # 选过滤后的(唯一)候选
  ab_wait 400
  ab_key " $2"
  ab_press 'Enter'
}

# --- 断言 ---
assert_url(){ # substr msg
  [[ "$(ab_eval '(()=>location.pathname+location.search)()')" == *"$1"* ]] && pass "$2" || fail "$2 (url 不含 '$1')"
}
assert_visible(){ # selector msg
  if ab_wait "$1"; then pass "$2"; else fail "$2 (元素不可见: $1)"; fi
}
assert_text(){ # selector substr msg
  local got; got=$(ab_eval "(()=>{const e=document.querySelector('$1');return e?e.textContent:'';})()")
  [[ "$got" == *"$2"* ]] && pass "$3" || fail "$3 (元素 '$1' 不含 '$2')"
}
assert_dispatch(){ # expected msg  (expected 用 | 分隔多个可接受值,如 ok|idle)
  local d; d=$(ab_dispatch)
  if [[ "|$1|" == *"|$d|"* ]]; then pass "$2 (data-last-dispatch=$d)"; else fail "$2 (data-last-dispatch=$d,期望 $1)"; fi
}
# agent 回复气泡(data-mine=false)是否含某文本
assert_agent_reply(){ # substr msg  [timeout_s]
  local sub="$1" msg="$2" to="${3:-12}" i
  for ((i=0;i<to;i+=3)); do
    local got; got=$(ab_eval "(()=>Array.from(document.querySelectorAll('[data-sender-kind=agent][data-mine=false]')).map(b=>b.textContent).join('\\u0001'))()")
    [[ "$got" == *"$sub"* ]] && { pass "$msg (回复含 '$sub')"; return; }
    ab_wait 3000
  done
  fail "$msg (${to}s 内 agent 无回复含 '$sub')"
}
# 断言"无 agent 回复含某标记"(回归守卫 / 负路径用)
assert_no_agent_reply(){ # substr msg timeout_s
  local sub="$1" msg="$2" to="${3:-15}"
  ab_wait "$((to*1000))"
  local got; got=$(ab_eval "(()=>Array.from(document.querySelectorAll('[data-sender-kind=agent][data-mine=false]')).map(b=>b.textContent).join('\\u0001'))()")
  [[ "$got" != *"$sub"* ]] && pass "$msg (确认 ${to}s 内无回复含 '$sub')" || fail "$msg (本应无回复却出现 '$sub')"
}

# agent 是否已存在(/identities/agents 列表)
agent_exists(){ # name
  ab_open "$BASE_URL/identities/agents"; ab_wait 1500
  [[ "$(ab_eval "(()=>document.querySelector('#world-root')?.textContent.includes('entity://system/agent/$1'))()")" == "true" ]]
}

summary(){
  printf '\n\033[1m══ 结果 ══\033[0m\n'
  c_g "PASS=$PASS"; [[ $SKIP -gt 0 ]] && c_y "SKIP=$SKIP"; [[ $FAIL -gt 0 ]] && c_r "FAIL=$FAIL"
  if [[ $FAIL -gt 0 ]]; then printf '失败项:\n'; printf '  - %s\n' "${FAILED_LINES[@]}"; return 1; fi
  return 0
}

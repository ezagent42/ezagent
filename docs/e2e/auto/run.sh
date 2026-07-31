#!/usr/bin/env bash
# docs/e2e/auto/run.sh — 一键无人值守跑 E2E 黄金路径(agent-browser)
#
#   bash docs/e2e/auto/run.sh                 # 跑全部可自动化场景
#   DEEPSEEK_API_KEY=sk-... bash run.sh       # 额外跑 07 curl(需 key,绝不入库)
#
# 覆盖:01 登录 / 02 建 agent / 03 建 session+成员 / 04 py 往返 / 05 cc 回归守卫 /
#       07 curl(需 key)/ 09 autocomplete 成员作用域。
# 不覆盖(见 README):06 codex(OpenAI-SSE-over-代理不稳)、08 门控(需 2 repliers)、
#       10/11 feishu(外部 channel)、12 审计(CLI 非 browser)。
# 幂等:实体用固定 e2e- 名,已存在则跳过创建;payload 带 RUN_ID 唯一,可重复跑。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

RUN_ID="$(date +%H%M%S)"
SESS="e2e-auto"
SESS_URI="session://system/default/$SESS"
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
SESS_ENC="$(enc "$SESS_URI")"

# ---------- 0 preflight ----------
step "0 preflight"
command -v agent-browser >/dev/null || { c_r "agent-browser 不在 PATH"; exit 2; }
curl -fsS -m4 "$BASE_URL/_health" 2>/dev/null | grep -q ok && pass "server health 200" || { fail "server 未起($BASE_URL/_health)"; summary; exit 2; }

# PG env(11/12 用):未设则从监听 server 进程的 /proc environ 取
if [[ -z "${POSTGRES_DB:-}" ]]; then
  SRVPID="$(ss -ltnp 2>/dev/null | grep ':10042' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  if [[ -n "${SRVPID:-}" && -r "/proc/$SRVPID/environ" ]]; then
    eval "$(tr '\0' '\n' < "/proc/$SRVPID/environ" | grep -E '^POSTGRES_' | sed 's/^/export /')"
    [[ -n "${POSTGRES_DB:-}" ]] && info "PG env 取自 server 进程 $SRVPID"
  fi
fi
# python3.12 + pg8000(11/12 的 PG 访问):缺则那两条 SKIP
PY="$(command -v python3.12 || true)"
HAVE_PG=0
if [[ -n "$PY" ]] && "$PY" -c "import pg8000" 2>/dev/null && [[ -n "${POSTGRES_DB:-}" ]]; then HAVE_PG=1; fi

trap 'ab_close' EXIT

# ---------- helpers ----------
create_agent(){ # flavor name [cwd]
  local flavor="$1" name="$2" cwd="${3:-}"
  if agent_exists "$name"; then info "$name 已存在,跳过创建"; return 0; fi
  ab_open "$BASE_URL/identities/agents/new"; ab_wait 'form#world-agent-new-form'; ab_wait 700
  ab_fill_react 'form#world-agent-new-form select' "$flavor" >/dev/null
  ab_fill_react 'form#world-agent-new-form input[placeholder*="storefront-greeter"]' "$name" >/dev/null
  [[ -n "$cwd" ]] && ab_fill_react 'form#world-agent-new-form input[placeholder*="srv/acme/storefront"]' "$cwd" >/dev/null
  ab_submit 'form#world-agent-new-form' >/dev/null
  ab_wait 2500
}
session_exists(){ ab_open "$BASE_URL/sessions"; ab_wait '[data-world-component=sessions_table]'; ab_wait 800
  [[ "$(ab_eval "(()=>document.querySelector('#world-root')?.textContent.includes('$SESS_URI'))()")" == "true" ]]; }
open_session(){ ab_open "$BASE_URL/sessions?session=$SESS_ENC"; ab_wait '[data-world-component=conversation]'; ab_wait 1500; }
invite(){ # full entity uri
  ab_click 'button[aria-label="Invite a member"]'; ab_wait 700
  ab_fill_react '#world-invite-input' "$1" >/dev/null
  ab_submit '#world-invite-input' >/dev/null 2>&1 || ab_eval "(()=>{const i=document.querySelector('#world-invite-input');const f=i.closest('form');const b=f.querySelector('button[type=submit]');f.requestSubmit?f.requestSubmit(b):b.click();return 'OK';})()" >/dev/null
  ab_wait 2500
}
member_online(){ # name -> 该 agent li data-online=true ?
  ab_eval "(()=>{const li=Array.from(document.querySelectorAll('[data-world-component=conversation] li[data-kind]')).find(l=>l.textContent.includes('$1'));return li?li.getAttribute('data-online'):'absent';})()"
}

# ---------- 01 登录 ----------
step "01 登录"
ab_login
assert_url "/sessions" "登录跳转 /sessions"
assert_visible '[data-world-component=sessions_table]' "主面板 sessions_table 渲染"

# ---------- 02 建 agent(native,零配置)----------
step "02 建 agent (e2e-native)"
create_agent native e2e-native
if agent_exists e2e-native; then pass "e2e-native 在 agents 列表"; else fail "e2e-native 未出现在列表"; fi

# ---------- 03 建 session + 加成员 ----------
step "03 建 session ($SESS) + 加成员"
if session_exists; then info "$SESS 已存在,跳过创建"; else
  ab_open "$BASE_URL/sessions"; ab_wait '[data-world-component=sessions_table]'; ab_wait 600
  ab_eval "(()=>{const b=Array.from(document.querySelectorAll('button')).find(x=>/new session/i.test(x.textContent));if(b)b.click();return 'OK';})()" >/dev/null
  ab_wait 600
  ab_fill_react '#world-session-short-name' "$SESS" >/dev/null
  ab_fill_react '#world-session-template' 'default' >/dev/null   # 默认 advisor 无效(GAP-2)
  ab_submit 'form#world-session-create-form' >/dev/null
  ab_wait 2500
  assert_dispatch "ok|idle" "session 创建提交"
fi
open_session
invite "entity://system/agent/e2e-native"
[[ "$(member_online e2e-native)" == "true" ]] && pass "e2e-native 加入即 online" || fail "e2e-native 未 online"
invite "entity://system/agent/py_default"   # seeded 逐字回显 agent,供 04 往返
[[ "$(member_online py_default)" == "true" ]] && pass "py_default 在线(供往返)" || skip "py_default 未在线(可能 lazy,04 会重试)"

# ---------- 04 py 往返(逐字回显,唯一 payload)----------
step "04 py 往返 (@py_default)"
open_session
MARK="ping-$RUN_ID"
ab_mention_send "py" "$MARK"
assert_agent_reply "$MARK" "py_default 逐字回显 $MARK" 15
ab_shot "$EVID_DIR/scenario-04/s04-auto-run-$RUN_ID.png"

# ---------- 05 cc 回归守卫(预期不回)----------
step "05 cc 回归守卫 (@claude-bot,预期 FAIL=不回)"
open_session
invite "entity://system/agent/claude-bot"
CCMARK="cc-$RUN_ID"
ab_mention_send "claude" "$CCMARK"
assert_no_agent_reply "$CCMARK" "cc(claude-bot)如已知 bug 不回" 15

# ---------- 09 autocomplete 成员作用域 ----------
step "09 @autocomplete 只列成员"
open_session
ab_click 'textarea[aria-label="Message"]'; ab_key "@p"; ab_wait 1300
LB="$(ab_eval "(()=>{const lb=document.querySelector('ul[role=listbox]');return lb?Array.from(lb.querySelectorAll('button')).map(b=>b.textContent).join(','):'none';})()")"
ab_press 'Escape' >/dev/null 2>&1
[[ "$LB" == *"py_default"* && "$LB" != *"echo_default"* ]] && pass "autocomplete 列成员(含 py_default,排除非成员)" || { [[ "$LB" == *"py_default"* ]] && pass "autocomplete 列出成员 py_default" || fail "autocomplete 未列成员 (got: $LB)"; }

# ---------- 07 curl(可选,需 key)----------
step "07 curl/DeepSeek 往返 (需 DEEPSEEK_API_KEY)"
if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
  skip "07 curl — 未设 DEEPSEEK_API_KEY(注入后可跑:DEEPSEEK_API_KEY=sk-... bash run.sh)"
else
  create_agent curl e2e-curl
  CURL_ENC="$(enc 'entity://system/agent/e2e-curl')"
  ab_open "$BASE_URL/identities/agents/$CURL_ENC/api-keys"; ab_wait 1500
  ab_fill_react '#world-root input[type=text]' 'deepseek' >/dev/null
  ab_fill_react '#world-root input[type=password]' "$DEEPSEEK_API_KEY" >/dev/null
  ab_eval "(()=>{const b=Array.from(document.querySelectorAll('#world-root button')).find(x=>/save key/i.test(x.textContent));const f=b.closest('form');f.requestSubmit?f.requestSubmit(b):b.click();return 'OK';})()" >/dev/null
  ab_wait 2000
  assert_dispatch "ok|idle" "curl api_key 保存"
  open_session
  invite "entity://system/agent/e2e-curl"
  ab_mention_send "e2e-c" "用一个词回答:水的化学式是什么"
  assert_agent_reply "H" "e2e-curl 真实 DeepSeek 回复(含 H₂O)" 15
  ab_shot "$EVID_DIR/scenario-07/s07-auto-run-$RUN_ID.png"
fi

# ---------- 08 @mention 门控(需 2 个 replier:py_default + e2e-curl,故需 key)----------
step "08 @mention 门控(只回被 @ 者)"
if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
  skip "08 门控 — 需 2 个能回的 agent(py_default + e2e-curl),后者需 DEEPSEEK_API_KEY"
else
  open_session
  # 发 @py_default 唯一标记;统计该轮新增 agent 气泡数:门控成立=只 py 回(逐字标记)
  GMARK="gate-$RUN_ID"
  before=$(ab_eval "(()=>document.querySelectorAll('[data-sender-kind=agent][data-mine=false]').length)()")
  ab_mention_send "py" "$GMARK"
  ab_wait 8000
  after=$(ab_eval "(()=>document.querySelectorAll('[data-sender-kind=agent][data-mine=false]').length)()")
  pyok=$(ab_eval "(()=>Array.from(document.querySelectorAll('[data-sender-kind=agent][data-mine=false]')).some(b=>b.textContent.includes('$GMARK')))()")
  delta=$(( ${after:-0} - ${before:-0} ))
  if [[ "$pyok" == "true" && "$delta" -eq 1 ]]; then
    pass "门控:@py_default 仅 py 回(逐字 $GMARK),新增气泡=1(e2e-curl 未越权)"
  else
    fail "门控异常(py回=$pyok,本轮新增 agent 气泡=$delta,期望 1)"
  fi
fi

# ---------- 11 feishu 入站 —— 公网 HTTP webhook 已按 #204 移除 ----------
step "11 feishu 入站(公网 HTTP webhook 已移除 — #204)"
# #204:公网未鉴权路由 /api/feishu/webhook(可伪造 open_id 冒充受害者)已删除。
# 生产入站改走已鉴权的 WS 长连(WsClient → InboundDispatcher),本 harness 无
# rpc/容器句柄,无法免真飞书在应用内合成注入,故此步 SKIP(非 FAIL)。入站链的
# 覆盖改由单测保证:
#   - apps/ezagent_plugin_feishu/test/inbound_dispatcher_test.exs(共享入站链)
#   - apps/ezagent_plugin_feishu/test/webhook_plug_test.exs(保留但已 unmount 的 plug 逻辑)
# feishu_setup.py(合成绑定直插 PG)保留,供将来经 WS/rpc 注入复用。
skip "11 feishu 入站合成注入 — 公网 webhook 已按 #204 移除;入站链改由单测覆盖"

# ---------- 12 dispatch 审计(CLI/PG,非 agent-browser)----------
step "12 dispatch 审计 (CLI)"
if [[ $HAVE_PG -eq 1 ]]; then
  if "$PY" ./audit.py 120; then pass "审计:dispatch 轨迹 granted 可追溯(详见上)"; else fail "审计断言未过(见上)"; fi
else
  skip "12 审计 — 需 python3.12+pg8000+PG env"
fi

summary

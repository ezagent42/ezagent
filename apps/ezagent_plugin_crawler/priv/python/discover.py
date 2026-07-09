# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
discover.py — `dealscout-discover` recipe 的 python script（py flavor 车道）。

## 这个 script 是什么（D1 落地形态，2026-07-10 段3）

dealscout 的 discover 角色槽从 cc-headless 换到 `dealscout-discover` recipe ×
`py` flavor（绕开 cc-headless 物化崩溃的平台 gap，走 hello builder/responser
已验证的 np×py 同一装配车道：`Recipe.script` → sandbox_content → config_dir
`agent.py`）。

## py 车道的真实契约（读码结论，不是假设）

`py` flavor 的 wire 是单方法 `receive(params: {text, from, session}) ->
{"text": str} | None`（`EzagentPluginPy.BridgeAdapter` :in_process_sync）。
Domain.Python V1 **刻意不支持 Python → BEAM 请求**（ezagent_python SPEC
§2.3），所以本 script **不能** dispatch `crawler.crawl_now`——"收消息→调
action"形态在 py 车道不存在。真实支持的形态是"**回复中自带触发**"：

  1. 被 @（mention-gated 默认路由）/ 被路由到时，`receive` 在本 sandbox 里
     **真实爬取** HN Algolia 公开检索源（与 `EzagentPluginCrawler.Fetch` 的
     缺省公开源同源；stdlib urllib，无 token 无依赖）；
  2. 把发现的线索连同**更新信号标记**一起作为回复发回会话（回复以 discover
     成员身份 `session.send`，见 `Ezagent.ActionSet.PyAgent.maybe_reply_effect`）；
  3. manifest 的 routing 规则 and(text_contains <信号>, from_role discover)
     命中这条回复 → 触发 page 角色。

  爬取失败 / 零命中时回复**不带**信号标记（没有新线索就不谎报"已入库"，
  fail-honest）。

## 更新信号标记是注入的，不是硬编码

UPDATE_SIGNAL 的占位符（Recipes.update_signal_placeholder/0）在 recipe 装配时
（`EzagentPluginCrawler.Recipes.discover_script/0`）被替换为
`Ezagent.ActionSet.Crawler.update_signal/0` ——
manifest YAML 是该字面量的权威载体（Decision #156 契约锁方向），本 script 与
Crawler 常量同为 emit 侧镜像，由 `dealscout_manifest_test.exs` 锁一致。
占位符若未被替换，import 时 fail-loud（subprocess 起不来，物化当场红），
绝不带着错误信号上线静默失配。

## 千人千面-lite（措辞与实现相符，D4 诚实化）

没有 LLM：按触发消息里的关键词（≥3 字符的词）对标题做包含匹配粗筛，无命中
则回退最新条目。这是 scripted 发现流；真"AI 发现"（LLM 大脑）是后续
curl-llm 槽的事（design spec D1 note），本 script 不冒充。
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

# Required by SPEC §6.3: Domain.Python sets EZAGENT_PYTHON_LIB_DIR
# pointing at apps/ezagent_domain_python/priv/python/.
sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])

from ezagent_python import log, method, run  # noqa: E402

# recipe 装配时替换（Recipes.discover_script/0）；权威字面量载体是 manifest
# YAML 的 routing text_contains arg。未替换 = 装配 bug → fail-loud。
UPDATE_SIGNAL = "{{update_signal}}"
if "{{" in UPDATE_SIGNAL:
    raise RuntimeError(
        "discover.py: update-signal placeholder was not substituted at "
        "recipe build time — refusing to start with a broken signal contract"
    )

# 与 EzagentPluginCrawler.Fetch 的缺省公开源同源（front_page 检索，公开无
# token）；关键词粗筛用同一 API 的 query 参数。
SEARCH_URL = "https://hn.algolia.com/api/v1/search"
HTTP_TIMEOUT_S = 6  # BEAM 侧 receive 超时缺省 10s，务必留余量
MAX_LEADS = 5


def _http_get_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "ezagent-dealscout-discover"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _keywords(text: str) -> list[str]:
    """触发消息 → 粗筛关键词（≥3 字符的词；剔除 @mention 与信号标记）。"""
    if not isinstance(text, str):
        return []
    cleaned = text.replace(UPDATE_SIGNAL, " ")
    words = re.findall(r"[\w-]{3,}", cleaned, flags=re.UNICODE)
    return [w.lower() for w in words if not w.startswith("@")][:8]


def _fetch_hits(keywords: list[str]) -> list[dict]:
    """真实抓取：有关键词先按 query 检索，零命中/无关键词回退 front_page。"""
    if keywords:
        q = urllib.parse.urlencode({"query": " ".join(keywords)})
        data = _http_get_json(f"{SEARCH_URL}?{q}")
        hits = data.get("hits") or []
        if hits:
            return hits
    data = _http_get_json(f"{SEARCH_URL}?tags=front_page")
    return data.get("hits") or []


def _format_lead(hit: dict) -> str:
    title = hit.get("title") or hit.get("story_title") or "(untitled)"
    url = hit.get("url") or hit.get("story_url") or ""
    points = hit.get("points")
    suffix = f"（{points} points）" if isinstance(points, int) else ""
    return f"- [public] {title} — {url}{suffix}"


@method("ping")
def ping(_params):
    return {"ok": True}


@method("receive")
def receive(params):
    """py-agent wire 入口：真实爬公开源 → 线索 + 更新信号一起回进会话。

    返回 `{"text": ...}`；**只有真的抓到线索才带 UPDATE_SIGNAL**（routing 的
    text_contains 靶子）。抓取失败降级为不带信号的诚实说明——绝不空发
    "有新线索已入库"。任何异常不往外抛（BEAM 侧会记 last_error，但用户
    只会看到沉默），统一转为降级回复。
    """
    text = params.get("text", "") or ""

    try:
        hits = _fetch_hits(_keywords(text))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
        log("warning", "discover crawl failed", error=f"{type(e).__name__}: {e}")
        return {"text": f"本轮未发现新线索：抓取公开源失败（{type(e).__name__}），未发更新信号。"}

    leads = [_format_lead(h) for h in hits[:MAX_LEADS]]
    if not leads:
        return {"text": "本轮未发现新线索：公开源返回为空，未发更新信号。"}

    header = f"{UPDATE_SIGNAL} 新线索 {len(leads)} 条（discover 爬取 HN 公开检索源）"
    return {"text": "\n".join([header, *leads])}


if __name__ == "__main__":
    run()

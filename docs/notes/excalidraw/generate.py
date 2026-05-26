#!/usr/bin/env -S uv run --
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
Generate Excalidraw scenes for the Ezagent architecture primer.

Output: architecture-primer.excalidraw  (single file with 4 diagrams).

Open at https://excalidraw.com via "Open" → pick the .excalidraw file.
Pan/zoom to navigate between diagrams stacked vertically.

Design intent (2026-05-26 v2 after Allen feedback): match the primer doc's
abstraction level — clean nested boxes, no implementation details inside.
"""
import json
import os
import time

# ─────────────────────────────────────────────────────────────────────────
# element builders
# ─────────────────────────────────────────────────────────────────────────

elements: list[dict] = []
_id_counter = 0


def _id() -> str:
    global _id_counter
    _id_counter += 1
    return f"el{_id_counter:04d}"


def _seed() -> int:
    return int.from_bytes(os.urandom(4), "big")


def _now() -> int:
    return int(time.time() * 1000)


def _base() -> dict:
    return {
        "angle": 0,
        "strokeColor": "#1e1e1e",
        "backgroundColor": "transparent",
        "fillStyle": "solid",
        "strokeWidth": 2,
        "strokeStyle": "solid",
        "roughness": 1,
        "opacity": 100,
        "groupIds": [],
        "frameId": None,
        "roundness": None,
        "seed": _seed(),
        "version": 1,
        "versionNonce": _seed(),
        "isDeleted": False,
        "boundElements": [],
        "updated": _now(),
        "link": None,
        "locked": False,
    }


def rect(x, y, w, h, *, fill="#ffffff", stroke="#1e1e1e",
         strokew=2, rounded=True, dashed=False) -> str:
    rid = _id()
    el = _base()
    el.update({
        "type": "rectangle", "id": rid,
        "x": x, "y": y, "width": w, "height": h,
        "strokeColor": stroke, "backgroundColor": fill,
        "strokeWidth": strokew,
        "strokeStyle": "dashed" if dashed else "solid",
        "roundness": {"type": 3} if rounded else None,
    })
    elements.append(el)
    return rid


def text(x, y, w, h, content, *, font=20, align="center",
         container=None, color="#1e1e1e") -> str:
    tid = _id()
    el = _base()
    el.update({
        "type": "text", "id": tid,
        "x": x, "y": y, "width": w, "height": h,
        "strokeColor": color, "strokeWidth": 1,
        "text": content, "fontSize": font,
        "fontFamily": 1,
        "textAlign": align, "verticalAlign": "middle",
        "baseline": int(font * 0.85),
        "containerId": container,
        "originalText": content,
        "lineHeight": 1.25,
    })
    elements.append(el)
    if container:
        for e in elements:
            if e["id"] == container:
                e["boundElements"] = (e["boundElements"] or []) + [
                    {"id": tid, "type": "text"}
                ]
                break
    return tid


def box(x, y, w, h, label, *, fill="#ffffff", stroke="#1e1e1e",
        font=20, rounded=True, dashed=False, strokew=2,
        color="#1e1e1e") -> str:
    rid = rect(x, y, w, h, fill=fill, stroke=stroke,
               strokew=strokew, rounded=rounded, dashed=dashed)
    text(x, y, w, h, label, font=font, container=rid, color=color)
    return rid


def arrow(x1, y1, x2, y2, *, dashed=False, label=None,
          color="#1e1e1e") -> str:
    aid = _id()
    el = _base()
    el.update({
        "type": "arrow", "id": aid,
        "x": x1, "y": y1,
        "width": abs(x2 - x1), "height": abs(y2 - y1),
        "strokeColor": color, "strokeWidth": 2,
        "strokeStyle": "dashed" if dashed else "solid",
        "roundness": {"type": 2},
        "points": [[0, 0], [x2 - x1, y2 - y1]],
        "lastCommittedPoint": None,
        "startBinding": None,
        "endBinding": None,
        "startArrowhead": None,
        "endArrowhead": "arrow",
    })
    elements.append(el)
    if label:
        midx, midy = (x1 + x2) / 2, (y1 + y2) / 2
        text(midx - 60, midy - 12, 120, 24, label,
             font=14, color="#555555")
    return aid


def heading(x, y, content, *, font=30, w=900):
    text(x, y, w, font + 10, content, font=font, align="left")


def sub(x, y, content, *, font=15, w=900):
    text(x, y, w, font + 6, content, font=font,
         align="left", color="#666666")


# ─────────────────────────────────────────────────────────────────────────
# palette — soft pastels, same hue family
# ─────────────────────────────────────────────────────────────────────────

C_WS = "#dbeafe"     # workspace blue
C_SE = "#fef3c7"     # session amber
C_US = "#ede9fe"     # user purple
C_AG = "#dcfce7"     # agent green
C_RE = "#ffedd5"     # resource orange
C_SY = "#fce7f3"     # system pink
C_TM = "#f1f5f9"     # template gray
C_CORE = "#e0e7ff"   # core indigo
C_DOM = "#ccfbf1"    # domain teal
C_PLG = "#fef9c3"    # plugin yellow
C_INFRA = "#e0f2fe"  # infra cyan


# =========================================================================
# Diagram 1 — WSER hierarchy (simple nested boxes, no internal bullets)
# =========================================================================
heading(60, 30, "1 · WSER 业务层级")
sub(60, 75, "workspace → session → entity → resource，旁挂 template / system")

# workspace (outer container)
ws_x, ws_y, ws_w, ws_h = 60, 130, 900, 460
box(ws_x, ws_y, ws_w, 60,
    "workspace://team-alpha    （部署单元 / 租户根）",
    fill=C_WS, font=22)
rect(ws_x, ws_y, ws_w, ws_h, fill="transparent", dashed=True, strokew=2)

# session inside
se_x, se_y = ws_x + 40, ws_y + 100
se_w, se_h = ws_w - 80, 320
box(se_x, se_y, se_w, 50,
    "session://default/team-alpha/main    （多 Agent 房间）",
    fill=C_SE, font=18)
rect(se_x, se_y, se_w, se_h, fill="transparent", dashed=True, strokew=2)

# three entities (large, simple labels)
eu_w, eu_h, gap = 230, 170, 25
eu_x = se_x + 35
eu_y = se_y + 90
box(eu_x, eu_y, eu_w, eu_h,
    "entity://user\n\nAlice\n（真实用户）",
    fill=C_US, font=18)
box(eu_x + (eu_w + gap), eu_y, eu_w, eu_h,
    "entity://agent\n\ncc_helper\n（AI Agent）",
    fill=C_AG, font=18)
box(eu_x + 2 * (eu_w + gap), eu_y, eu_w, eu_h,
    "resource://uploads\n\nfile-abc\n（资产引用）",
    fill=C_RE, font=18)

# template stack to the right (loosely coupled — just labels)
tp_x = ws_x + ws_w + 60
tp_y = ws_y + 80
tp_w, tp_h = 260, 130
box(tp_x, tp_y, tp_w, tp_h,
    "template://agent\n\nAgentTemplate\n（agent 配方）",
    fill=C_TM, font=16, dashed=True)
box(tp_x, tp_y + tp_h + 40, tp_w, tp_h,
    "template://session\n@hash\n\nSessionTemplate\n（session 配方）",
    fill=C_TM, font=16, dashed=True)

# instantiate arrows — clear, no text crossing boxes
ag_cx = eu_x + (eu_w + gap) + eu_w / 2
arrow(tp_x, tp_y + tp_h / 2, ag_cx + 100, eu_y + 20,
      dashed=True, label="实例化")
arrow(tp_x, tp_y + tp_h + 40 + tp_h / 2,
      se_x + se_w - 20, se_y + 25,
      dashed=True, label="实例化")

# system (two pink boxes below workspace)
sy_y = ws_y + ws_h + 40
box(ws_x, sy_y, 440, 80,
    "system://routing/default\n平台横切：全局路由表",
    fill=C_SY, font=16)
box(ws_x + 460, sy_y, 440, 80,
    "system://bootstrap/default\n开机时刻的 sentinel principal",
    fill=C_SY, font=16)


# =========================================================================
# Diagram 2 — Message journey (clean vertical pipeline)
# =========================================================================
DY = 900
heading(60, 30 + DY, "2 · 一条消息的旅程")
sub(60, 75 + DY, "不管哪种输入，最终都走同一条调度流水线")

# external inputs (single horizontal bar, simplified)
ex_y = 130 + DY
box(60, ex_y, 900, 70,
    "外部输入  ·  HTTP   飞书   Slack   CLI   Web   MCP",
    fill="#fde68a", font=20)

# adapter
ad_y = ex_y + 110
box(60, ad_y, 900, 70,
    "适配器 (Adapter)  ·  把外部协议翻译成统一调用请求",
    fill="#fef3c7", font=18)
arrow(510, ex_y + 70, 510, ad_y, dashed=False)

# dispatch (one big rounded box with steps as plain text rows inside)
ds_y = ad_y + 110
ds_h = 380
rect(60, ds_y, 900, ds_h, fill="#dbeafe", dashed=False, strokew=2)
box(60, ds_y, 900, 50,
    "统一调度流水线 (Dispatch)",
    fill="#dbeafe", font=22)

step_y0 = ds_y + 70
step_h = 40
step_gap = 10
steps = [
    "① 找目标对象",
    "② 权限检查  →  失败则 unauthorized",
    "③ workspace 隔离  →  失败则 cross_workspace_denied",
    "④ 参数校验",
    "⑤ 执行能力 (Behavior)",
    "⑥ 状态变化 → 快照落盘",
    "⑦ 异步审计日志",
]
for i, lbl in enumerate(steps):
    y = step_y0 + i * (step_h + step_gap)
    box(90, y, 840, step_h, lbl, fill="#ffffff", font=16)
arrow(510, ad_y + 70, 510, ds_y, dashed=False)

# reply
rp_y = ds_y + ds_h + 30
box(60, rp_y, 900, 70,
    "回复通道  ·  按「原路返回」把结果回到调用方",
    fill="#bbf7d0", font=18)
arrow(510, ds_y + ds_h, 510, rp_y, dashed=False)


# =========================================================================
# Diagram 3 — Three-tier engineering (clean stack)
# =========================================================================
DY = 1950
heading(60, 30 + DY, "3 · core / domain / plugin 三层组装")
sub(60, 75 + DY, "判定规则：这段代码读什么数据？通用→core，业务→domain，插件特定→plugin")

# plugin (top)
tier_w, tier_h, tier_gap = 900, 130, 40
pg_y = 130 + DY
box(60, pg_y, tier_w, tier_h,
    "plugin   ·   可选扩展（每个独立 OTP app）\n\n"
    "cc / curl / echo / np  ·  feishu  ·  liveview",
    fill=C_PLG, font=18, dashed=True)

# domain (middle)
dm_y = pg_y + tier_h + tier_gap
box(60, dm_y, tier_w, tier_h,
    "domain   ·   必装的一类对象（互相允许依赖，无环）\n\n"
    "chat  ·  identity  ·  workspace  ·  external_mirror",
    fill=C_DOM, font=18, dashed=True)

# core (bottom)
co_y = dm_y + tier_h + tier_gap
box(60, co_y, tier_w, tier_h,
    "core   ·   基础原语（不依赖任何业务）\n\n"
    "URI · Dispatch · Capability · 注册表 · 可靠性 · 持久化 · 路由",
    fill=C_CORE, font=18, dashed=True)

# dependency arrows
arrow(510, pg_y + tier_h, 510, dm_y, label="依赖", color="#666666")
arrow(510, dm_y + tier_h, 510, co_y, label="依赖", color="#666666")


# =========================================================================
# Diagram 4 — Panorama (top-to-bottom, then split for business + infra)
# =========================================================================
DY = 2700
heading(60, 30 + DY, "4 · 全景图")
sub(60, 75 + DY, "外部输入 → 适配器 → 调度 → 业务对象 + 横切基础设施")

# external + adapter + dispatch (vertical column)
ex_y = 130 + DY
box(60, ex_y, 900, 60,
    "外部世界  ·  HTTP / 飞书 / CLI / Web / MCP",
    fill="#fde68a", font=18)

ad_y = ex_y + 90
box(60, ad_y, 900, 60,
    "适配器层",
    fill="#fef3c7", font=18)
arrow(510, ex_y + 60, 510, ad_y, dashed=False)

ds_y = ad_y + 90
box(60, ds_y, 900, 80,
    "统一调度流水线\n权限 · workspace 隔离 · 执行 · 落盘 · 审计",
    fill="#dbeafe", font=18)
arrow(510, ad_y + 60, 510, ds_y, dashed=False)

# split into two columns
sp_y = ds_y + 110
col_w = 430
col_gap = 40

# Business column
box(60, sp_y, col_w, 50,
    "业务对象（WSER）", fill=C_WS, font=20)
biz_items = [
    ("workspace://", "部署单元 / 租户根", C_WS),
    ("session://", "多 Agent 房间", C_SE),
    ("entity:// (user)", "真实用户", C_US),
    ("entity:// (agent)", "AI Agent", C_AG),
    ("resource://", "资产引用", C_RE),
    ("template://", "配方", C_TM),
    ("system://", "平台横切", C_SY),
]
for i, (head, desc, color) in enumerate(biz_items):
    box(60, sp_y + 70 + i * 60, col_w, 50,
        f"{head}    —    {desc}", fill=color, font=15)

# Infra column
infra_x = 60 + col_w + col_gap
box(infra_x, sp_y, col_w, 50,
    "横切基础设施", fill=C_INFRA, font=20)
infra_items = [
    "ReadyGate · 就绪门",
    "PendingDelivery · 启动期缓冲",
    "Idempotency · 幂等去重",
    "DLQ · 死信队列",
    "Routing · 三层叠加",
    "Audit · 异步审计",
    "Snapshot · 变更落盘",
]
for i, lbl in enumerate(infra_items):
    box(infra_x, sp_y + 70 + i * 60, col_w, 50,
        lbl, fill=C_INFRA, font=15)

# dispatch → both columns
arrow(60 + col_w / 2, ds_y + 80, 60 + col_w / 2, sp_y, dashed=False)
arrow(infra_x + col_w / 2, ds_y + 80, infra_x + col_w / 2, sp_y, dashed=False)

# footer: 3-tier note
ft_y = sp_y + 70 + 7 * 60 + 30
box(60, ft_y, 900, 70,
    "工程纵轴：core ▲ domain ▲ plugin\n"
    "北极星：插件作者只写一个 OTP app，不碰 core",
    fill="#f1f5f9", font=15)


# =========================================================================
# emit
# =========================================================================

scene = {
    "type": "excalidraw",
    "version": 2,
    "source": "https://excalidraw.com",
    "elements": elements,
    "appState": {
        "gridSize": None,
        "viewBackgroundColor": "#ffffff",
    },
    "files": {},
}

out_path = os.path.join(
    os.path.dirname(__file__), "architecture-primer.excalidraw"
)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(scene, f, ensure_ascii=False, indent=2)

print(f"wrote {out_path}  ({len(elements)} elements)")

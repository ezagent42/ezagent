# Soul / Skill / KB 三层设计 — 方案导览

**完整 SPEC**: `docs/superpowers/specs/2026-06-04-soul-skill-kb-design.md`
**架构图**: `docs/superpowers/specs/2026-06-04-soul-skill-kb-diagram.excalidraw`
**状态**: r14 — Codex 4 轮 review (r3/r9/r11/r13) 全部闭合，0 CRITICAL
**分支**: `autoservice-dev`

---

## 一句话

将旧 AutoService 的 soul/skill/flow_chunk/KB 迁移到 ezagent **三层模型** (Soul / Skill / KB)，**不建新 Kind/Behavior/Action/Scheme**，domain/core 零变更。

---

## 核心模型: 三层 + 槽位

```
                加载方式              大小         有 {{slot}}?
                ────────              ────         ──────────
Soul            始终在 prompt 中       ~15KB 预算   ✅
(inline)        渲染进 CLAUDE.md                    {{key}} 占位符

Skill       磁盘 .md 文件         无限制        ✅ 可 (Phase 2)
(on-disk)       Read 工具按需加载                   MVP 直接 copy
                索引注入 soul

KB              MCP tool 查询          无限制        ❌
(queryable)     不占 prompt                         结构化数据 + 可信策略配置
                                                    system only
```

### 为什么是三层

旧 AutoService 四层 (soul/skill/flow_chunk/KB) 中 skill 和 flow_chunk 加载方式完全相同 (磁盘文件 + Read on demand)，合并为 Skill。旧 soul 76KB 不是必须 — 解剖后真正 inline 的只有 ~15KB:

```
旧 soul 76KB → 新架构:
  Soul inline:     ~15KB (身份/安全/分类 + {{slot}} key 引用 + Skill 索引)
  Skill:       ~12KB (详细流程, Read on demand)
  KB:              ~80KB (产品术语, MCP query, 不占 prompt)
```

### AutoService 实施验证

AutoService 基于本 SPEC 独立实现，Phase 0 实测: soul 1337→440 行，p50 TTFT ≥100ms 改善，~1,027 LOC 可删除。

---

## 关键特点

1. **domain 零变更, core 零变更** — `soul_slot_values` 作为 flavor-owned content key
2. **不建新抽象** — 不新 Kind/Behavior/Action/Scheme (P8)
3. **模板文件(SoT) + 槽位 Slice(SoT)** → render_slots → agent sandbox (Projection)
4. **分离由 Template Authoring Agent 分析 + 人类 review** — 不由旧约定
5. **渐进收敛** — 冷启动: 骨架模板 → 先宽后严 → 试运行驱动锁定
6. **Soul lint gate** — warn>25KB / error>30KB CI gate (Phase 3)
7. **路径自带权限** — workspace-scoped CapBAC 等效，不需要额外 RBAC 字段
8. **~380 LOC** (plugin + LV)，+1 key per flavor template_data_extra/1

---

## 编辑: dispatch template.read + template.write

```
Tenant LV:
  template.read → 改 soul_slot_values → template.write
  (已有 action, 不新增)
```

## 四步数据流

```
1. CREATE (seed)        2. FORK (已有)         3. EDIT (已有)        4. RENDER
解析旧 yaml             Behavior.Template      LV → read →            File.read(模板)
→ 默认 slot 值          :fork                  改 slot_values        + render_slots()
→ template.write        → tenant workspace     → template.write      → CLAUDE.md
```

---

## SPEC 章节导览

| § | 内容 | 适合谁 |
|---|------|--------|
| §1 | 核心模型: 三层 + 分离判据 + AutoService 实施经验 | 所有人 |
| §2 | 模板从哪里来 (迁移/冷启动/三层决策) | 产品/架构 |
| §3 | 变更清单 (domain 归零的理由) | 架构/开发 |
| §4 | 文件布局约定 + Skill discovery 机制 | 开发 |
| §5 | 编辑流程 (LV + dispatch + Editor Agent) | 开发 |
| §6 | 渲染流程 (Template Class instantiate) | 开发 |
| §7 | 模板更新传播 (re-spawn 约束) | 架构 |
| §8 | KB 管理 (含 escalation_keywords 处理) | 开发 |
| §9 | 实施序列 + LOC (~380 plugin+LV) | PM/开发 |
| §10 | 完整数据流图 | 所有人 |
| §11 | 不变式自查 | 架构 |
| §12 | 延后清单 | PM |
| §13 | 潜在风险与待审查问题 | 安全/架构 |

---

## 图

打开 [excalidraw.com](https://excalidraw.com)，拖入 `docs/superpowers/specs/2026-06-04-soul-skill-kb-diagram.excalidraw`。

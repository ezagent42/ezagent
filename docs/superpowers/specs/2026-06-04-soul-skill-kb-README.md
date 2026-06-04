# Soul / Skill / KB 设计 — 最终方案

**SPEC 文件**: `docs/superpowers/specs/2026-06-04-soul-skill-kb-design.md`
**图**: `docs/superpowers/specs/2026-06-04-soul-skill-kb-diagram.excalidraw`
**状态**: r12 — Codex r11 闭合 (0 CRITICAL)，domain/core 零变更

---

## 一句话

将旧 AutoService 的 soul(人格)/skill(技能)/KB(知识库) 迁移到 ezagent 三层模型 (Soul/Reference/KB)，**不建任何新 Kind/Behavior/Action/Scheme**。全部复用已有机制。

---

## 核心模型: 三层 + 槽位

```
Soul (~15KB, inline prompt)
  ├─ 身份、安全规则、分类逻辑、升级策略
  ├─ {{slot}} 占位符 → soul_slot_values (Slice flavor extra)
  └─ Reference 索引 ("X 场景 → Read Y 文件")

Reference (磁盘文件, Read on demand)
  ├─ 合并旧 skills + flow_chunks
  ├─ 可选 {{slot}} (MVP: 直接 copy; Phase 2: 支持 slot 渲染)
  └─ 大小无限制

KB (MCP query, 不占 prompt)
  ├─ 产品术语、价格、规格 (glossary)
  ├─ 可信策略配置 (escalation_keywords)
  └─ 结构化数据, system only
```

### 为什么 3 层不是 4 层

旧系统 76KB soul 是迭代膨胀 — 没有 slot 机制、没有 KB 分离、没有 Reference 提取，什么都往 soul 塞。解剖后发现真正 inline 的只有 ~15KB。旧 `skill` vs `flow_directive` 标签是历史产物 (加载方式完全相同)，合并为 Reference。

---

## 特点

1. **domain 零变更** — `soul_slot_values` 作为 flavor-owned content key (已有 `template_data_extra/1` 机制)
2. **core 零变更** — 不碰 ezagent 核心
3. **不建新抽象** — 不新 Kind/Behavior/Action/Scheme (P8)
4. **模板(文件) + 槽位(Slice) 双层 SoT** — 模板结构在 `priv/` 文件 (人类可读)，槽位值在 Slice (dispatch 可编辑)
5. **分离由 Template Authoring Agent 分析 + 人类 review** — 不由旧约定决定什么进哪层
6. **渐进收敛** — 冷启动: 骨架模板 → 先宽后严 → 试运行数据驱动锁定

---

## 编辑: dispatch template.read + template.write

Tenant LV: `template.read` → 改 `soul_slot_values` → `template.write`。不新增 action。

---

## 图

打开 [excalidraw.com](https://excalidraw.com)，拖入 `docs/superpowers/specs/2026-06-04-soul-skill-kb-diagram.excalidraw` 文件。

---

## SPEC 章节导览

| § | 内容 | 适合谁 |
|---|------|--------|
| §1 | 核心模型：三层 + 槽位 + 分离判据 + 谁判断执行 | 所有人 |
| §2 | 模板从哪里来 (迁移/冷启动/三层决策) | 产品/架构 |
| §3 | 变更清单 (domain 归零的理由) | 架构/开发 |
| §4 | 文件布局约定 (三层目录结构) | 开发 |
| §5 | 编辑流程 (LV + dispatch + Editor Agent) | 开发 |
| §6 | 渲染流程 (Template Class instantiate) | 开发 |
| §7 | 模板更新传播 (re-spawn 约束) | 架构 |
| §8 | KB 管理 (含 escalation_keywords 处理) | 开发 |
| §9 | 实施序列 + LOC (~380 plugin+LV) | PM/开发 |
| §10 | 完整数据流图 | 所有人 |
| §11 | 不变式自查 | 架构 |
| §12 | 延后清单 | PM |
| §13 | 潜在风险与待审查问题 | 安全/架构 |

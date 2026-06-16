# Worktree vs autoservice-dev — 方案对比评估

> 2026-06-16

## 两分支概况

| | autoservice-dev | 本 worktree (ui-impl-session2) |
|---|---|---|
| Base | `3679e353` | `cdfd00ac` (设计文档 commit，早了 18 个 commit) |
| 理念 | TenantAdminLive hub + 独立页面 + 统一 Sidebar | 独立 LiveView 页面 + 各自导航 |
| 文件数 | 9 admin + 2 components | 12 admin + 4 components |
| 进度 | P0 完成 + P1 部分 + 36项 checklist | P0 完成 + P1 完成 |

---

## autoservice-dev 独有优势

### 1. 统一导航架构
- **`admin_sidebar.ex`** — 所有 admin 页面共享的左侧导航栏，链接到 Soul/Slot/Skill/KB/CR/Versions/Dashboard
- **`TenantAdminLive` hub** — 仪表盘中枢页，集成 AdminSidebar，tab 式布局
- 本 worktree 每个 LiveView **各自独立**，缺少统一导航

### 2. 后端增强（本 worktree 没有的）
- `kb_store.ex` — PDF + XLSX 文件上传支持（`extract_pdf_text`, `extract_xlsx_text`）
- `tenant_config.ex` — 额外的租户配置变更
- `CrEngine` — sandbox diff 计算（`compute_sandbox_diff/1`）
- KB chunk_text/1 — 段落语义切分
- 回滚恢复 sandbox 文件

### 3. 实施规划完整
- `docs/superpowers/plans/2026-06-16-autoservice-p0-p2-checklist.md` — 36 项 × 5 批
- `docs/superpowers/specs/2026-06-16-autoservice-admin-gap-priority.md` — 64 项 gap 分析
- 本 worktree 只有 PRD 摄入的 YAML，缺少后端的 gap-checklist

---

## 本 Worktree 独有优势

### 1. 额外完成的页面
- **`fast_prompt_editor_live.ex`** (P1-1) — Fast Agent Prompt 独立编辑器
- **`sandbox_preview_live.ex`** (P1-2) — 沙箱预览独立页
- autoservice-dev 缺这两页（checklist 中标记为 Batch 5）

### 2. 额外组件
- **`cr_tracked_changes.ex`** — CR sandbox_diff 可视化组件
- **`kb_source_list.ex`** — KB source 列表组件
- autoservice-dev 未抽取这两个组件

### 3. 更好的 TenantDashboard 交互
- Init banner **可关闭**（Skip for now）
- Dashboard 内容 **始终可见**（不被 init 遮挡）
- Setup Wizard **常驻入口**（可重复进入）
- autoservice-dev 待验证

### 4. Operators 真实实现
- `Users.delete/1` 真实调用（非 stub flash）
- autoservice-dev checklist 标记为 Batch 5 #30

---

## 差距对比（36 项 checklist 覆盖情况）

基于 autoservice-dev 的 `2026-06-16-autoservice-p0-p2-checklist.md`：

| Batch | 项目 | autoservice-dev | 本 worktree |
|-------|------|:--:|:--:|
| B1 P0 核心修复 | 4 项 | 部分完成 | 0/4 |
| B2 P1 编辑体验 | 7 项 | 0/7 | 0/7 |
| B3 P1 KB 增强 | 5 项 | 部分完成 | 0/5 |
| B4 P1 CR 完善 | 4 项 | 0/4 | 0/4 |
| B5 P2 补齐 | 14 项 | 0/14 | 0/14 |
| **额外 P1 页面** | FastPrompt + SandboxPreview | ❌ | ✅ 已完成 |

---

## 建议方案

### 推荐：合并到 autoservice-dev 并继续

1. **将本 worktree 的 4 个独有文件移植到 autoservice-dev**:
   - `fast_prompt_editor_live.ex`
   - `sandbox_preview_live.ex`
   - `cr_tracked_changes.ex`
   - `kb_source_list.ex`
   - `operators_live.ex`（真实 disable 实现）

2. **采用 autoservice-dev 的导航架构**:
   - `admin_sidebar.ex` 统一侧边栏
   - TenantAdminLive hub 模式

3. **按 autoservice-dev 的 36 项 checklist 继续推进**:
   - Batch 1-4 为 P0-P1 完整交付
   - Batch 5 为 P2+

### 移植清单

```
从本 worktree 移植到 autoservice-dev:
  1. fast_prompt_editor_live.ex         → autoservice/admin/
  2. sandbox_preview_live.ex            → autoservice/admin/
  3. cr_tracked_changes.ex              → autoservice/admin/components/
  4. kb_source_list.ex                  → autoservice/admin/components/
  5. operators_live.ex (disable 实现)   → tenant/
  6. tenant_dashboard_live.ex (可选)    → tenant/ (如果 init banner 交互更好)

从 autoservice-dev 不需要移植到本 worktree（因为要弃用本 worktree）:
  — 本 worktree 作为参考分支保留，不再继续实施
```

---

## 决策点

1. **是否确认转向 autoservice-dev？** 放弃本 worktree 的独立路线
2. **哪些本 worktree 的文件要移植？** 全部 6 个还是部分？
3. **TenantDashboard 用哪个版本？** autoservice-dev 的 vs 本 worktree 的（可 dismiss init banner）
4. **移植后下一步优先级？** 按 36 项 checklist 的 Batch 1-4 推进

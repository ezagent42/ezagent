# AutoService Admin 功能 UI 实现评估报告

> **日期**: 2026-06-15
> **范围**: AutoService v2 设计需求 vs 后端实现 vs 前端 UI 实现
> **参考**: `docs/superpowers/specs/2026-06-10-autoservice-v2-design.md` §8
> **分支**: `autoservice-dev` (based on `main` `a39c4e66`)

---

## 一、总体评估

| 功能模块 | 后端 | 前端 UI | 状态 |
|---------|:----:|:------:|:----:|
| **租户管理** (Tenant) | ✅ | ⚠️ | 基本完整，Operator 管理有 stub |
| **CR 管理** (Content Review) | ✅ | ⚠️ | Publish/Cancel 可用，CR History 为 placeholder stub |
| **Soul 编辑** | ✅ | ✅ | 完整可用 |
| **Skill 编辑** | ✅ | ❌ | 后端完整，前端只读列表，无编辑能力 |
| **KB 编辑** | ✅ | ❌ | 后端完整 (CRUD + MCP + rebuild)，前端无任何 UI |
| **Fast Agent 提示词编辑** | ⚠️ | ❌ | 后端无显式 prompt 编辑 API，前端无 UI |
| **Platform 内容管理** | ✅ | ❌ | 后端有 PlatformSoulStore/PlatformSkillStore，前端无页面 |

**结论**: 后端实现覆盖 6/7，前端 UI 完整覆盖仅 1.5/7（Soul 编辑完整 + 租户管理基本完整）。Phase C 缺失 3 个独立页面（skill_editor、kb_manager、platform_content）和 2 个可编辑功能（Skill 编辑、Fast agent 提示词编辑）。

---

## 二、逐模块详细对比

### 2.1 租户管理 (Tenant Management)

#### 需求 (§8.1, §8.2)
- Master Admin: 租户列表、新建租户向导、租户概览
- Tenant Admin: Operator 管理（列表/新增/禁用）、品牌信息编辑
- 租户创建流程：workspace + sandbox init + 初始 CR + soul/skill 骨架

#### 后端实现 ✅
| 模块 | 功能 |
|------|------|
| `Behavior.TenantAdmin` | `create_tenant/3` — 新建租户 workspace + sandbox + CR 引导 |
| `TenantProvisioner` | `create_tenant/3` — 目录结构 + 骨架 soul + 平台 skills + slots.yaml 初始化 |
| `TenantConfig` | `read_config/1`, `read_cr/2` — 读取租户配置和 CR 记录 |
| `TenantRuntime` | `sandbox_path/1`, `release_path/1`, `materialize/3` — 路径管理 |
| `Behavior.WorkspaceUserAdmin` | `create_user/3` — 创建用户 |

#### 前端 UI ⚠️
| 页面 | 模块 | 状态 |
|------|------|:--:|
| `/admin/autoservice` | `MasterDashboardLive` | ✅ 租户列表、数量概览、CR 统计 |
| `/admin/autoservice/tenants/new` | `TenantOnboardLive` | ✅ 3 步向导（基本信息 → 管理员账号 → 初始化） |
| `/admin/autoservice/tenants/:tid` | `TenantDashboardLive` | ✅ 版本概览、CR 状态、快捷链接 |
| `/admin/autoservice/tenants/:tid/operators` | `OperatorsLive` | ⚠️ 列表 + 新增可用，**禁用为 stub**（"not yet implemented"） |

#### Gap
- Operator 禁用功能：后端 `Behavior.WorkspaceUserAdmin` 无 `disable_user` action，前端按钮已渲染但点击提示未实现

---

### 2.2 CR 管理 (Content Review Management)

#### 需求 (§8.5)
- CR 发布流程: lint → snapshot → mark-before-flip → atomic symlink flip
- CR 取消、修复（repair half-finished publish）
- CR 历史记录查看
- 发布前 lint 检查结果展示

#### 后端实现 ✅
| 模块 | 功能 |
|------|------|
| `CrEngine` | `publish/1` — 全流程发布（lint→snapshot→mark→flip→published） |
| `CrEngine` | `repair_current/1` — 修复半完成发布 |
| `CrEngine` | `cancel/1` — 取消活跃 CR |
| `CrLint` | `check/1` — R01-R05 五条 lint 规则 |
| `CrSnapshot` | `snapshot/1` — sandbox → release/v<N> |
| `CrRollback` | `rollback/2` — 回滚到历史版本 |

#### 前端 UI ⚠️
| 页面 | 模块 | 状态 |
|------|------|:--:|
| `/admin/autoservice/tenants/:tid/cr` | `CrDashboardLive` | ✅ Publish / Cancel / Refresh 按钮可用 |
| 同上 | 同上 | ❌ **CR History 为 placeholder stub**（空 div，注释 `CR History (placeholder)`） |
| `/autoservice/admin` | `TenantAdminLive` | ✅ 内嵌 publish 按钮 + lint 结果展示 |

#### Gap
- CR 历史记录：后端 `TenantConfig.read_cr/2` 可读取指定 CR，但前端无列表渲染

---

### 2.3 Soul 编辑

#### 需求 (§8.3)
- 编辑 tenant 的 customer.md soul template
- 编辑 slot_values (customer.yaml) 变量替换
- 模板预览（渲染后的 CLAUDE.md）
- Publish 触发 CR 流程
- Sanbox 预览验证

#### 后端实现 ✅
| 模块 | 功能 |
|------|------|
| `ContentAdmin` | `write_soul_slot/4` — 写 soul slot 值 + 自动创建 CR |
| `SoulStore` | `read_slots/4`, `write_slots/5` — YAML 读写，deep merge |
| `SoulLoader` | `load/3` — 4 层模板加载（framework→platform→industry→tenant） |
| `SoulRenderer` | `render/2`, `full_claude_md/3` — `{{key}}` 替换 + CLAUDE.md 生成 |
| `SoulSlotParser` | `parse_slots/1` — 模板中 `{{key}}` 占位符解析 |
| `PlatformSoulStore` | `read_soul/2`, `write_soul/3`, `delete_soul/2` — 平台级 soul 模板 CRUD |

#### 前端 UI ✅
| 页面 | 模块 | 功能 |
|------|------|------|
| `/autoservice/admin` | `TenantAdminLive` | ✅ Soul 编辑（textarea 编辑 customer.md） |
| 同上 | 同上 | ✅ Slots 编辑（YAML textarea） |
| 同上 | 同上 | ✅ Publish 按钮（触发 CrEngine.publish） |
| 同上 | 同上 | ✅ Preview 按钮（读 sandbox soul+slots 渲染内联预览） |
| 同上 | 同上 | ✅ Refresh Lint（触发 CrLint，展示结果） |
| 同上 | 同上 | ✅ Skills 只读列表 |

#### Gap
- 无。Soul 编辑是**唯一完整闭环**的功能模块。

---

### 2.4 Skill 编辑

#### 需求 (§8.3)
- 4 层 Skill 浏览（tenant / industry / platform / framework），tab 切换
- 文件列表（每层 list skills）
- 代码编辑器（编辑 SKILL.md）
- 新建/删除 Skill

#### 后端实现 ✅
| 模块 | 功能 |
|------|------|
| `ContentAdmin` | `write_skill/4`, `delete_skill/3` — 写/删 skill，走 CapBAC dispatch |
| `SkillStore` | `read/4`, `write/5`, `delete/4` — 文件 CRUD（仅写 sandbox） |
| `SkillLoader` | `list/4` — 4 层扫描，同层覆盖 |
| `SkillIndexer` | `build/3` — 生成 Skill Index markdown，提取 frontmatter 元数据 |
| `PlatformSkillStore` | `list_skills/1`, `read_skill/2`, `write_skill/3`, `delete_skill/2` — 平台级 CRUD |

#### 前端 UI ❌
| 功能 | 状态 |
|------|:--:|
| Skill 文件列表 | ⚠️ `TenantAdminLive` 中为**只读列表**（列出文件名，不可点击/编辑） |
| Skill 编辑器 | ❌ 不存在。设计需求 §8.3 要求独立 `skill_editor_live.ex`（4 层 tab + 代码编辑器） |
| 新建/删除 Skill | ❌ 不存在 |
| Platform Skill 管理 | ❌ `platform_content_live.ex` 未创建 |

#### Gap
- **独立页面缺失**: `skill_editor_live.ex`（设计 §8.3 要求）
- **编辑功能缺失**: TenantAdminLive 中的 skill 列表只读，无编辑入口
- **Platform 管理缺失**: `platform_content_live.ex`（设计 §8.5 要求）

---

### 2.5 KB 编辑 (Knowledge Base)

#### 需求 (§8.4)
- KB 条目 CRUD（搜索框、列表、编辑表单）
- KB 源管理（URL 抓取、文件上传、glossary 导入）
- KB 重建（rebuild kb.db）
- Escalation keywords 配置
- Per-agent KB MCP 集成

#### 后端实现 ✅
| 模块 | 功能 |
|------|------|
| `ContentAdmin` | `upsert_kb/1`, `delete_kb/1` — KB 条目 CRUD，走 CapBAC |
| `KbStore` | `search/2`, `upsert/2`, `delete/2` — Python MCP 脚本调用 |
| `KbRebuilder` | `rebuild/2` — 重建 kb.db（glossary + sources） |
| `KbMcpProvider` | `config/2` — 生成 per-agent `.mcp.json` |

#### 前端 UI ❌
| 功能 | 状态 |
|------|:--:|
| KB 条目列表/搜索 | ❌ 不存在 |
| KB 条目编辑（新增/编辑/删除） | ❌ 不存在 |
| KB 源管理（URL 抓取/文件上传） | ❌ 不存在 |
| KB 重建触发 | ❌ 不存在 |
| Escalation keywords | ❌ 不存在 |

#### Gap
- **独立页面完全缺失**: `kb_manager_live.ex`（设计 §8.4 要求，含搜索框 + URL 抓取 + 文件上传）
- TenantAdminLive 中无任何 KB 相关 UI

---

### 2.6 Fast Agent 提示词编辑

#### 需求
- 编辑 fast agent (DeepSeek curl) 的 ACK prompt（`fast_ack_prompt.md`）
- 编辑 fast agent system_prompt
- fast agent 提示词从 sandbox 读取（与 cc agent soul 同理）
- CR publish 后通过 dispatch 重建 agent prompt

#### 后端实现 ⚠️
| 模块 | 功能 |
|------|------|
| `Refresh` | `after_publish/2` — publish 后刷新 fast agent system_prompt（调用 dispatch） |
| `CustomerSession` | `provision/2` — 创建 fast agent 时无显式 prompt 注入 |
| `AutoserviceAssembly` | `provision_agent/2` — 同上，agent 配置从 `agents.yaml` 读取 |

后端 **有** publish 后的 prompt 刷新逻辑，但**缺少**独立的 "编辑 fast agent prompt" API。当前 prompt 是通过 agent template 的 `system_prompt` 字段固化在 template data 中，不支持 sandbox 文件编辑。

#### 前端 UI ❌
| 功能 | 状态 |
|------|:--:|
| Fast agent prompt 编辑器 | ❌ 不存在 |
| TenantAdminLive 中无 fast_ack_prompt.md 编辑入口 | ❌ 不存在 |

#### Gap
- **后端**: 需要将 fast agent prompt 管理对齐为 sandbox 文件模型（类似于 soul 编辑），或通过 AgentTemplate 更新 API
- **前端**: TenantAdminLive 可扩展一个 "Fast Agent Prompt" tab，参考 Soul 编辑模式

---

### 2.7 Platform 内容管理

#### 需求 (§8.5)
- Master Admin 全局 soul/skill/KB 模板编辑（影响所有租户的框架层）
- Soul 模板: framework / platform / template 三级编辑
- Skill 模板: 4 层管理
- 独立页面 `/admin/autoservice/platform/soul`

#### 后端实现 ✅
| 模块 | 功能 |
|------|------|
| `PlatformSoulStore` | `read_soul/2`, `write_soul/3`, `delete_soul/2` |
| `PlatformSkillStore` | `list_skills/1`, `read_skill/2`, `write_skill/3`, `delete_skill/2` |

#### 前端 UI ❌
`platform_content_live.ex` 未创建。

---

## 三、缺失清单汇总

### 完全缺失的页面 (3)

| 页面 | 文件 | 设计参考 | 所需后端 | 复杂度 |
|------|------|---------|---------|:--:|
| **Skill Editor** | `skill_editor_live.ex` | §8.3 | `ContentAdmin` + `SkillStore` + `PlatformSkillStore` (已就绪) | 中 |
| **KB Manager** | `kb_manager_live.ex` | §8.4 | `ContentAdmin` + `KbStore` + `KbRebuilder` (已就绪) | 高 |
| **Platform Content** | `platform_content_live.ex` | §8.5 | `PlatformSoulStore` + `PlatformSkillStore` (已就绪) | 中 |

### 现有页面中的 stub/缺失 (3)

| 页面 | 缺失功能 | 后端状态 |
|------|---------|:--:|
| `OperatorsLive` | Operator 禁用 | ❌ 后端 `WorkspaceUserAdmin` 无 `disable_user` action |
| `CrDashboardLive` | CR History 列表 | ✅ 后端 `TenantConfig.read_cr/2` 已就绪 |
| `TenantAdminLive` | Skill 编辑能力 | ✅ 后端 `ContentAdmin.write_skill/delete_skill` 已就绪 |
| `TenantAdminLive` | KB 编辑入口 | ✅ 后端 `ContentAdmin.upsert_kb/delete_kb` 已就绪 |
| `TenantAdminLive` | Fast Agent 提示词编辑 | ⚠️ 后端需新增 sandbox prompt 文件读写 |

---

## 四、优先级建议

| 优先级 | 功能 | 理由 |
|:------:|------|------|
| **P0** | TenantAdminLive 集成 Skill 编辑 | 后端就绪，只需在现有页面加编辑能力，一次性解决最大 gap |
| **P0** | TenantAdminLive 集成 KB 编辑 | 同上 |
| **P1** | Skill Editor 独立页面 | 后端就绪，独立页面提升体验（4 层 tab 切换） |
| **P1** | KB Manager 独立页面 | 后端就绪，需要搜索 + 上传等复杂 UI |
| **P2** | CR Dashboard 历史记录 | 后端就绪，纯展示 |
| **P2** | Fast Agent 提示词编辑 | 需后端新增 sandbox prompt API + 前端编辑器 |
| **P2** | Platform Content 管理 | 后端就绪，面向 Master Admin |
| **P3** | Operator 禁用 | 需后端新增 `disable_user` action |

---

## 五、TenantAdminLive 当前功能对照

`/autoservice/admin` — `EzagentPluginLiveview.Tenant.TenantAdminLive`

| 功能 | 实现 | 备注 |
|------|:--:|------|
| Soul 编辑 (customer.md) | ✅ | textarea 编辑 + 保存 |
| Slots 编辑 (customer.yaml) | ✅ | textarea YAML 编辑 + 保存 |
| Publish (CR 触发) | ✅ | 调用 CrEngine.publish |
| Preview (sandbox 预览) | ✅ | 内联渲染 soul+slots |
| Lint 检查 | ✅ | CrLint 结果展示 |
| Skills 列表 | ⚠️ | **只读** — 列出文件名，不可编辑 |
| KB 管理 | ❌ | 无任何 UI |
| Fast Agent Prompt | ❌ | 无任何 UI |
| Cap Gate | ✅ | `has_content_write_cap?/2` 权限检查 |

---

> **生成工具**: Claude Code
> **分支**: `autoservice-dev` @ `6e89eb7b`

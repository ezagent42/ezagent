# AutoService Admin — P0~P2 实施 Checklist

> 基于 `docs/superpowers/specs/2026-06-16-autoservice-admin-gap-priority.md`
> 34 项，分 5 批执行

---

## Batch 1: P0 核心修复（4项，今天必须完成）

- [ ] **1. KB 文本 Chunking** — `KbStore` 添加 `chunk_text/1`：段落切分（600char max, 50char min），`ingest_file`/`fetch_url` 调用 chunk
- [ ] **2. Sandbox Diff 计算** — `CrEngine.compute_sandbox_diff/1`：hash 对比 sandbox vs release 的 soul/slots/skills/kb，CR Dashboard 显示变更列表
- [ ] **3. 回滚恢复 Sandbox** — `VersionTimelineLive` 回滚时从 release 复制文件到 sandbox
- [ ] **4. Skill Frontmatter 解析** — `SkillManagerLive` 解析 `---\n...\n---` frontmatter，SkillCard 显示 description/intent_trigger

---

## Batch 2: P1 编辑体验（7项）

- [ ] **5. ETag 并发控制（Soul/Slot）** — mount 时计算 SHA-256 ETag，保存时 If-Match 检查
- [ ] **6. ETag 并发控制（Skill）** — 同上
- [ ] **7. Template Slot 验证** — SlotEditor 保存时验证 key 是否在 Soul template 中声明
- [ ] **8. Skill L0/L1 目录分离** — `SkillLoader` 区分 framework(L0) vs platform(L1) 目录
- [ ] **9. Seed Endpoint 增强** — InitWizard Step1 增强 Soul 生成逻辑
- [ ] **10. Composed Soul Preview 验证** — 确保 Preview tab 输出的 CLAUDE.md 与 runtime 一致
- [ ] **11. InitWizard URL/Doc Upload 步骤** — Step2 增加 URL 抓取和文件上传子步骤

---

## Batch 3: P1 KB 增强（5项）

- [ ] **12. PDF 语义提取** — 改进 `extract_pdf_text`：尝试 pdftotext → pypdf 回退，每页独立 chunk
- [ ] **13. XLSX 语义提取** — 改进 `extract_xlsx_text`：行列结构+sheet名，非纯文本拼接
- [ ] **14. 异步 Ingest Jobs** — URL 抓取/文件上传用 `Task.async` 异步，LiveView 不阻塞
- [ ] **15. FTS5 trigram CJK 搜索** — kb_search_mcp.py 启用 trigram tokenizer
- [ ] **16. Lint Severity 分级** — CrLint 添加 error/warning 分级，error 阻断发布

---

## Batch 4: P1 CR 完善（4项）

- [ ] **17. Per-item Publish** — `CrEngine.publish/2` 支持选择性发布部分 diff items
- [ ] **18. Per-item Revert** — `CrEngine.revert_item/2` 撤销单个文件改动
- [ ] **19. AI Assist 面板（SoulEditor）** — 接入 LLM 调用，聊天式交互
- [ ] **20. cc_pool Recycle 验证** — 验证 `Refresh.refresh_agents` 在 publish 后正确刷新

---

## Batch 5: P2 功能补齐（14项，可分批或延后）

### 5a — KB 增强（4项）
- [ ] **21. URL Crawler** — BFS 同域多页爬虫
- [ ] **22. KB Source 元数据** — source_url/latest_created_at/enabled 字段
- [ ] **23. 18列KB Schema** — domain/region/language 过滤字段
- [ ] **24. KB 异步 Job 状态追踪** — 可轮询的 job status

### 5b — CR 完善（5项）
- [ ] **25. CR 状态机** — 增加 ready_for_review/abandoned 状态
- [ ] **26. CR Actor 追踪** — 记录操作者
- [ ] **27. Release Manifest** — publish 时写 manifest.yaml
- [ ] **28. Publish Lock** — 并发发布锁
- [ ] **29. 原子化发布目录** — .partial→rename

### 5c — UI/体验（3项）
- [ ] **30. Operators disable/enable** — 完善操作员管理
- [ ] **31. Sandbox Preview 独立页面**
- [ ] **32. Section Browser（L0-L3树形）**

### 5d — AI + Admin Session（2项）
- [ ] **33. Admin Agent Behavior** — NL→dispatch 管理操作
- [ ] **34. Admin Session LiveView** — 聊天界面+卡片渲染

---
### 5e — Platform 管理（2项）
- [ ] **35. Master Platform Soul/Skills 管理页**
- [ ] **36. Master Skills（L0/L1/L2）管理页**

---

## 执行方式

每批用 `superpowers:subagent-driven-development`：
1. Dispatch implementer subagent（提供 task 详情+context）
2. Implementer 实现、测试、自审
3. Dispatch spec reviewer（验证与 spec 一致）
4. Dispatch code quality reviewer（验证代码质量）
5. Fix issues → commit → push
6. 下一 task

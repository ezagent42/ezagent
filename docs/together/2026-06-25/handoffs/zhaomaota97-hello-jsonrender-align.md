# Handoff — hello / json-render 对齐与稳定（zhaomaota97 / 张宁）

> **任务**: 让 hello 的 AI 生成页**真正渲染正确**，并稳定 hello 的整体结构。
> **分支**: `feat/hello-jsonrender-align`（off `main`，保持 rebase）
> **本周目标**: 团队日用（目标①）。官网搁置 —— 本任务是夯实 hello+官网共用的 json-render 底座。

## 背景（为什么）
#956 把**后端** catalog（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/spec.ex`）迁到了 **36 个大写 shadcn 组件**（`Stack/Card/Heading/Text/Button/...`），prompts 也按这套注入。但**前端渲染器没跟着迁** —— `apps/ezagent_plugin_hello/assets/src/catalog.ts` + `registry.tsx` 还是旧的 7 个小写组件（`page/section/heading/...`）+ 手写 inline style。结果 LLM 现在产出 `{"type":"Stack"}`，前端不认 → 页面渲染空/坏。这就是"官网太丑/json-render 没用好"的根因。

## 要做什么
1. **前端 catalog 对齐后端**：重写 `catalog.ts` + `registry.tsx`，让前端 @json-render catalog == `spec.ex` 的 36 个 shadcn 组件。**不要动 `spec.ex`（后端已正确，只读参考）。**
2. **用真 shadcn/Tailwind 组件实现**每个 catalog 节点（复用 world 已有的设计 token：`apps/ezagent_plugin_world/assets/src/styles.css` + `components/ui/primitives.tsx`），不要手写 inline style。
3. **验证 style 切换**：能切换/应用一套 per-session 的样式（design token / CSS 变量覆盖），页面跟着变。
4. **稳定 hello 整体结构**：shell（#956 的 `set_shell` HTML+CSS 通道）+ json-render body 的组合关系清晰、不互相破坏。

## DoD（完成定义 —— 四性质，逐条都要有证明）
- [ ] **目标派生/parity**：前端 catalog 的组件集合 == 后端 `spec.ex` 的 36 个组件（差集 = ∅）。给出对照（哪 36 个、都实现了）。
- [ ] **在用户面验证**：生成一个页面 → 在 `/socialware/customer` 真实渲染 → **agent-browser 截图**证明渲染正确（不是空/坏页），对标 demo `http://100.64.0.27:5173/` 的质量。
- [ ] **style 切换**：一次 per-session 样式切换生效的证明（截图前后对比或测试）。
- [ ] **回归**：前端渲染器的自动化测试（catalog 校验 + 一个渲染快照），坏了会被测出来；截图只是辅助。
- [ ] **CI 绿**：`precommit + check_invariants` 在 PR head 绿 + rebase 到当前 main。

## 关键文件
- 改：`apps/ezagent_plugin_hello/assets/src/{catalog.ts, registry.tsx, main.tsx}`
- 只读参考：`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/spec.ex`（+ `prompts.ex`）
- 复用设计 token：`apps/ezagent_plugin_world/assets/src/{styles.css, components/ui/primitives.tsx}`
- per-session shell/theme 通道：`TurnDriver.set_shell` + `Surface.handle_set_shell`
- 参考实现：`github.com/ezagent42/json-render-demo`（live: http://100.64.0.27:5173/）

## 必读
- skill `ezagent-developer`
- 本周期分析（lead 底稿，背景）：`docs/together/2026-06-24/review.zh_cn.md`
- dev-together skill（返还前先 rebase + 自测绿；DoD 四性质）

## 注意
- 跨层任务：后端已迁、你补前端 —— 这正是补"跨层 parity"的那一半。
- 触及 world assets 的设计 token 时遵守 `docs/guide/world-coordination.md`（声明面、串行改 `styles.css`）。

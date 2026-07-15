# 决策：kanban 去 GitHub 化 + mirror/gh 出插件（2026-07-15，用户定）

## 背景
生产部署在 **docker 隔离环境**。板侧边栏现有「登记 mirror token / gh token」两处，都不再需要。最新 main **已把 gh 做成独立 plugin**。

## 决策
1. **删掉板侧边栏的两处 token 登记**（mirror token 登记、gh token 登记）。
2. **mirror token 改成同步时临时填**：不再持久登记；同步到 mirror 时**弹框填名字**（token 在 plugin 里当场填）。
3. **同步 / gh 逻辑不在 kanban plugin 实现**。kanban plugin 只开放**手动填**：仓库地址、issue/pr 的 sha（纯数据链接，就是现存的 `register_pr` / `attach_code_file` 那类纯数据）。
4. **gh 走独立 gh plugin**——**方向确定但尚未落 main**（归 gaga AgentRuntime 域，在 watch；见 Allen note #1417 `docs/superpowers/notes/2026-07-15-demo-provisioning-constraints.md`：GitHub=插件、token 不进 agent 按用户代取、cap-gated、复用外部适配器插件形态）。**我之前判「gh=agent CLI」是错的，纠正：是 plugin。**
5. **本次 kanban 侧做法（用户 2026-07-16 定）**：**只保留 UI 功能、删掉现在的 gh 实现**（删板侧栏 gh token 登记 + 任何残留 gh 连接器逻辑），保留纯数据 repo 地址/issue-pr-sha 的手填与显示（register_pr/attach_code_file 纯数据）。**等 gh plugin 好了，kanban-assistant 再 dispatch 接入**（本次不实现 gh，也不写「检测 gh plugin」逻辑——那是 gh plugin 就绪后的接入活）。
6. 原因：docker 隔离生产环境，凭证/推送集中在专门 gh plugin（gaga 建），kanban 只管板数据 + 纯数据链接展示。
7. **note #1417 另一条与本改版对齐**：kanban cap 必须走治理 + `Ezagent.Cap.issue` 签发、**不直写 caps_json**（否则撞写侧 gate + 无尾 audit 拒）——正是本次发 operate 钥匙的姿势。

## 落地影响（待 rebase 到新 main 后核对）
- kanban plugin：删 mirror/gh token 登记的 UI + 存储；`sync_miro` 的 creds 从「持久登记」改「同步时弹框填名字」。（连接器现状见 `ezagent_plugin_kanban/.../behavior/kanban/connectors.ex`，GitHub 出站连接器此前已删、剩纯数据 link。）
- world 前端：板侧边栏去掉两处 token 输入。
- assistant 编排：新增「检测 gh plugin 在否 → push → dispatch gh plugin」流程（配方/skill 文本，非 kanban 代码）。
- 与 collab 模型改版（`2026-07-15-kanban-collab-model.md`）合并到同一次 kanban 重写里做。

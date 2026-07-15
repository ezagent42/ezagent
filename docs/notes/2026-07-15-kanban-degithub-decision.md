# 决策：kanban 去 GitHub 化 + mirror/gh 出插件（2026-07-15，用户定）

## 背景
生产部署在 **docker 隔离环境**。板侧边栏现有「登记 mirror token / gh token」两处，都不再需要。最新 main **已把 gh 做成独立 plugin**。

## 决策
1. **删掉板侧边栏的两处 token 登记**（mirror token 登记、gh token 登记）。
2. **mirror token 改成同步时临时填**：不再持久登记；同步到 mirror 时**弹框填名字**（token 在 plugin 里当场填）。
3. **同步 / gh 逻辑不在 kanban plugin 实现**。kanban plugin 只开放**手动填**：仓库地址、issue/pr 的 sha（纯数据链接，就是现存的 `register_pr` / `attach_code_file` 那类纯数据）。
4. **gh 走独立 gh plugin**（main 上已有；gh plugin 配置个人 ssh key）。装了 sw 后，**kanban-assistant 按「是否存在 gh plugin」决定**：agent 先按流程 push，再 **dispatch gh plugin** 自动填 issue/pr。
5. 原因：docker 隔离生产环境，凭证/推送应集中在专门 gh plugin（持 ssh key），kanban 只管板数据。

## 落地影响（待 rebase 到新 main 后核对）
- kanban plugin：删 mirror/gh token 登记的 UI + 存储；`sync_miro` 的 creds 从「持久登记」改「同步时弹框填名字」。（连接器现状见 `ezagent_plugin_kanban/.../behavior/kanban/connectors.ex`，GitHub 出站连接器此前已删、剩纯数据 link。）
- world 前端：板侧边栏去掉两处 token 输入。
- assistant 编排：新增「检测 gh plugin 在否 → push → dispatch gh plugin」流程（配方/skill 文本，非 kanban 代码）。
- 与 collab 模型改版（`2026-07-15-kanban-collab-model.md`）合并到同一次 kanban 重写里做。

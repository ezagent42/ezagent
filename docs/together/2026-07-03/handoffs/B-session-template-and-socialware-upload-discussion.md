# Handoff B — SessionTemplate 改动 + socialware 上传机制 讨论

- **类型**: `clarify_first`（研究 / 设计讨论，**不写实现代码**）。产出 = 对齐文档 + build 切片 + DoD。
- **建议 owner**: gaga 或熟悉 plugin-package 的 dev（可与 lead 对齐）。
- **必读 skill**: `ezagent-socialware`、`ezagent-developer`。
- **一句话目标**: 把「**新的 SessionTemplate 机制**」和「**socialware 上传/发布机制（package）**」看清楚、对齐,重点是**要讨论/要拍的问题**——尤其是「一个 socialware 到底怎么被上传/发布并出现在某个 SessionTemplate 里」这条链路目前**没打通**。

---

## 你要先看懂的当前机制（都已在 main 上，代码已核对）

**① SessionTemplate（会话怎么被配置）**
- `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`
  - 关键：**SPEC #324——没有静默的全局 `"default"` fallback**;建会话必须显式传 `opts[:workspace]`。
  - 携带 `default_workspace_uri`、`orchestrator_template_uri`、`routing_rules`、以及 `session_templates` content（**声明这个模板要装哪些 socialware Definition**）。
  - 近期改动：T1 把 `role/`→`recipe/`、`orchestrator_role`→`orchestrator_recipe`;fork（#1139）落地了「一键复制 session 配置建新会话」。
- **Definition 怎么被装进模板**：`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex`
  - `resolved_template_installs(content, workspace_uri)` / `behavior_set_for_template/2`：从模板 content 解析出要安装的 `[{Definition, ConfigObject, install_spec}]`;
  - `web_anon_access?/1` + `visibility_policy`（Definition 的 public/anon 可见性）。

**② socialware Definition（发布单元,T2 已胖化）**
- `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex`：`agents:[{recipe,role_name}]` + `views`(view=render ActionSet) + `bases`/`shape`。
- 这是「app」= 发布单元。装进 SessionTemplate 后随会话运行。

**③ package / 上传机制（一个包怎么被装进运行中的系统）**
- `apps/ezagent_core/lib/ezagent/plugin_package/manifest.ex`
  - **注意：是 `manifest.json`,不是 `package.yaml`**（`mix ezagent.plugin.install` 判 `File.exists?(".../manifest.json")`）。
  - manifest 字段:`slug/version/app/plugin_module/behaviors/template_classes/routing_tables/asset_entries/seed_refs/config_schema`。
  - **关键缺口**:`seed_refs` 目前**只支持 `kind: :recipe`**——`@type seed_ref :: %{kind: :recipe, ...}`;注释明确写「**socialware-definition seeding is a future enhancement; a `:socialware` seed_ref is REJECTED at parse time**」（manifest.ex:56-59）。
  - 即:**包能 seed「recipe」,但还不能 seed「socialware Definition」。**
- `apps/ezagent_core/lib/mix/tasks/ezagent.plugin.install.ex`：有 manifest.json 就走 plugin-package 全量 hot-load(seed definitions + 注册 assets)。
- 另一条路:#1134 里有 **publish-as-template**（`orchestrator/tools/templates.ex`、`session_creator/listing.ex`、`external_feed.ex` 的 public read）——即通过 Definition editor / 模板发布,而非 manifest 包。

---

## 重点：要讨论 / 要拍的设计问题

1. **「上传一个 socialware」到底走哪条路？（核心缺口）**
   - manifest 现在**拒收** `:socialware` seed_ref。三种走向:
     - (a) **扩 manifest**:让 `seed_refs` 支持 `kind: :socialware`(注释里说的 future enhancement)——包里带 socialware Definition,install 时 seed 进 DefinitionRegistry;
     - (b) **走 Definition editor / publish-as-template**（#1134 已有雏形）:不通过 manifest 包,而是运行时编辑/发布 Definition;
     - (c) 两条并存(包=分发,editor=运行时创作)。
   - **拍哪条**——这决定官网「上传 socialware」的后端到底调什么。

2. **`package.yaml` vs `manifest.json`**：lead 说的是 yaml,代码里是 json。是要**改成 yaml**,还是沿用 json 只是叫法对齐？（影响上传 UX 和文档措辞。）

3. **SessionTemplate 与「上传的 socialware」怎么接上**：一个新上传的 Definition,怎么出现在某个 SessionTemplate 的 `session_templates` content 里 → 建会话时被 `Installation` 装载？是上传即注册到 DefinitionRegistry + 模板引用其名字,还是别的绑定方式？

4. **SessionTemplate 近期改动的完整清单**：T1（role→recipe）、fork（#1139）之后,SessionTemplate 的**当前完整形状**是什么,有没有需要团队对齐的破坏性变化（尤其 SPEC #324「无静默 default」对建会话调用方的影响）。

5. **上传 UX（官网）**：文件 → 解析 → 安装 → 注册 Definition → 在 SessionTemplate 里可选。这条端到端链路里哪些已有、哪些缺。

---

## 交付物（clarify 阶段,不写实现）

一份对齐文档:
- 画出 **SessionTemplate → Definition → package/manifest** 三者当前的真实关系(含缺口:socialware seed 被拒);
- 逐条回答上面 5 个问题,给推荐(尤其问题 1 走 a/b/c 哪条);
- 拆 **build 切片**(每片一句话 + 落点文件),标出哪些是新写、哪些是补齐已有;
- 写 **DoD**(用户层:官网上传一个 socialware 包/定义 → 出现在可选模板 → 建会话能用,附 E2E 证明计划)。

**明确不做**：不写实现代码。

---

## 怎么快速看现状（命令）

```bash
# SessionTemplate
git show origin/main:apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex | sed -n '1,120p'
# Definition + 安装
git show origin/main:apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex | sed -n '1,140p'
# package manifest（注意 socialware seed 被拒那段）
git show origin/main:apps/ezagent_core/lib/ezagent/plugin_package/manifest.ex | sed -n '39,110p'
# install 任务
git show origin/main:apps/ezagent_core/lib/mix/tasks/ezagent.plugin.install.ex | sed -n '100,135p'
# #1134 的 publish-as-template 雏形
gh -R ezagent42/ezagent pr diff 1134 | grep -iE "publish|template|listing|external_feed|public"
```

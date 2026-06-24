# 飞书文档可读性核查 — mindmap attachment 的真相源决策

日期：2026-06-23
作者：架构研究员（Skill 1，file:line 实证）
背景：mindmap 产品节点挂 attachment。此前判断「CI 关键内容(Gherkin/spec)必须 inline 存 ezagent，feishu 文档因权限墙不可靠」。用户质疑：飞书文档和 feishu 插件是否相关？给了飞书授权后 ezagent 理论上能不能调 API 读飞书文档内容？本文逐条核查。

---

## 1. feishu 插件有没有「读飞书文档内容」的能力？

**结论：没有。feishu client 只调 IM(消息)和 auth API，零文档 API。**

`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/client.ex` 是全仓库唯一的飞书 HTTP client（moduledoc client.ex:10-12 明确「this plugin is the only HTTP client in the codebase」）。它调的飞书 API 端点穷举如下：

| 端点 | 用途 | file:line |
|---|---|---|
| `auth/v3/tenant_access_token/internal` | 用 app_id+app_secret 换 token | client.ex:395 |
| `im/v1/messages?receive_id_type=chat_id` | 发文本/图片/文件消息 | client.ex:210, 366 |
| `im/v1/messages/{id}/reactions` | 表情回应(ack) | client.ex:96 |
| `im/v1/messages/{id}/resources/{file_key}` | 下载**消息里的**附件(图/文件) | client.ex:249 |
| `im/v1/images` / `im/v1/files` | 上传图/文件以便发送 | client.ex:286, 307 |

全是 `auth/v3` + `im/v1`。grep 全插件 `docx / drive/v1 / wiki/v / bitable / document` —— 命中的全是 moduledoc 注释里的 URL 和 node_modules 噪声，**业务代码零命中**（grep 结果见核查记录）。即：

- **没有** `docx/v1/documents/{id}/blocks`（读 docx 正文）
- **没有** `drive/v1/files`（读云盘）
- **没有** `wiki/v2/spaces`（读知识库）
- **没有** `bitable/v1`（读多维表格）

`download_resource/4`(client.ex:54, :249) 看着像「读文档」，其实只能下载**飞书消息气泡里夹带的附件**(`im/v1/messages/{message_id}/resources/...`)——必须有一条飞书消息 + message_id + file_key 才行，跟「读一篇独立的飞书云文档」是两码事。

**凭证 scope**：feishu.yaml 模板只有三个字段——`app_id` / `app_secret` / `encrypt_key`（模板见 `apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex:62-63, :90`，client.ex:14-15 从 `system://credentials/feishu.yaml` 读）。**凭证文件里完全没有 OAuth scope / 权限位的概念**——权限位是在飞书开放平台后台勾选的，不在 ezagent 这边声明。当前后台需要的权限只有 IM 相关（发消息/读消息资源），因为代码只调这些。

---

## 2. 理论上能不能读？飞书的权限链条

「给了授权 ≠ 自动能读任意文档」。即使我们给 client 加上 docx API 调用，要真读到某篇文档的正文，飞书侧需要**两个独立前提同时满足**：

**前提① — app 开通文档权限位。**
在飞书开放平台后台给这个 app 勾选 `docx:document`（或 `docs:document.content:read` / `drive:drive` / `wiki:wiki` 等，按文档类型）。光有 `tenant_access_token` 不够——token 只是「我是哪个 app」的身份证，不附带文档读权限。没勾权限位 → API 返回权限错误(典型 99991672 之类)。

**前提② — 目标文档显式授权给这个 app/机器人。**
这是用户担心的核心。飞书云文档是**文档级 ACL**：即使 app 开了 `docx` 权限位，也**只能读「已经分享给这个 app」的文档**。具体要文档作者（或有管理权的人）把文档/文件夹/知识库分享给这个机器人应用（在文档「分享」面板里添加该 app 为协作者），或者文档放进 app 有权限的知识库空间。

也就是说权限链是：
```
tenant_access_token(身份)
  + 后台勾 docx 权限位(app 级能力)
  + 文档作者把这篇文档分享给 bot(文档级 ACL)
  ───────────────────────────────────────
  = 这一篇文档可读；换一篇没分享的，照样读不了
```

第②条是逐篇文档的人工动作，无法自动化兜底。**这正是「权限墙」的实质**：不是「授权一次全局可读」，而是「每篇文档都要作者主动分享，否则 bot 看不见」。

---

## 3. 对 attachment 模型的影响：现状是 A 还是 B？

artifact schema 现状（`apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex:501-502`）：
```elixir
defp normalize_artifact(a) do
  %{tool: sget(a, :tool), kind: sget(a, :kind), ref: sget(a, :ref), url: sget(a, :url)}
end
```
只存 `tool/kind/ref/url`，没有正文。

**现状是 (A) 死链 ref。** 因为第 1 节证明 feishu 插件**根本没有读文档的 client**——一个 feishu-doc attachment 现在就是一串 ref/url，ezagent 读不了正文，只能人点开飞书去看。

**要做到 (B) 可读 ref，需要补三样（缺一不可）：**
1. **feishu client 加 docx 读 API** —— 在 client.ex 新增 `read_docx/1` 之类，调 `docx/v1/documents/{id}/raw_content` 或 blocks 接口（新代码，遵守 P12 adapter pattern：飞书协议细节只能在 feishu adapter 里）。
2. **后台开 docx 权限位** —— 运维在飞书开放平台勾权限（第 2 节前提①）。
3. **每篇文档分享给 bot** —— 每个挂 attachment 的作者得把那篇文档分享给机器人（第 2 节前提②）。第 3 条是**逐文档的人工动作，且会失败**（作者忘了分享、文档被移走、权限被收回 → fetch 报权限错）。

**重判 CI 关键内容存哪：**

> **仍然强烈建议 CI 关键内容(Gherkin / spec / 验收标准) inline 存 ezagent，不要依赖 feishu 可读 ref。**

理由：
- 现状是 A，feishu-doc 现在就是死链，CI 拿不到正文——没得选。
- 即便将来做到 B，第 2 节的权限链有一环靠「作者逐篇分享」，这是**不可靠且会静默失效**的人工环节。CI gate 依赖的内容一旦因为没分享而 fetch 失败，就是 CI 红/拿不到判据，违反 ezagent「这条 message 没人接收谁会知道」的可靠性直觉。
- feishu-doc 适合做**给人看的补充 ref**（设计稿、讨论纪要、富文本），CI **判据**这种 load-bearing 内容应在真相源(ezagent 节点)内 inline 兜底。

可读 ref(B) 顶多是「锦上添花的展示增强」，**不能替代** inline 作为 CI 判据的真相源。

---

## 4. `content` 字段可行性核查

计划：给 `normalize_artifact` 产出的 map（现 `%{tool,kind,ref,url}`）加 `content` 字段存 inline markdown。逐项核查：

**① 不改 core？✅ 是。**
`normalize_artifact/2` 是 `behavior/mindmap.ex:501` 的**私有函数**（`defp`），artifact 是节点 state 里的一个普通 map 字段（mindmap.ex:362 `artifacts: &1.artifacts ++ [...]`）。加字段纯粹在 plugin behavior 内部数据结构上动，core 完全不感知。action 契约 `attach_artifact` 的 args 是 `%{id: :string, artifact: :map}`（mindmap.ex:100-101）——`artifact: :map` 是开放 map，多带一个 `content` 键**不需要改 action schema**。

**② 不违反单一真相源？✅ 是，反而强化。**
inline 内容存进 mindmap 节点的 state，节点本身就在 ezagent 事件流/快照里（真相源**内**）。这正是「真相源 = ezagent 非破坏入站」的体现——内容随节点持久化、随快照回放，不依赖任何外部系统。比存 feishu ref 更符合单一真相源。

**③ 过 gate？✅ 是。**
- 全仓库唯一的 grep gate 是 `scripts/socialware_substrate_gate.sh`，它扫的是 acyclic/domain 架构关键词（gate 脚本 :81-83），跟 artifact/content 字段毫无关系。
- 无 `.github/workflows/`（该目录不存在），没有 CI 层的 arch/doc/uri_query grep gate 会扫到这个改动。
- plugin 禁止 import 清单（EventLog / SnapshotStore / StateRebuilder / Router internals 等）——加 `content` 字段不 import 任何东西，不触线。
- `normalize_artifact` 是 `defp`，外部不可见，不进任何公共契约 grep。

**坑 / 注意点：**
- **快照膨胀**：inline markdown 进节点 state → 进 snapshot。大文档会撑大快照/事件。建议给 content 设软上限（如截断或只存 CI 必需的 Gherkin 片段），别把整篇飞书文档塞进去。
- **detach 用 ref 匹配**：`handle_detach_artifact`(mindmap.ex:365-370) 用 `a.ref == ref` 删除——加 content 不影响，但提醒 content 要跟着同一个 ref 走，别出现「有 content 没 ref」导致删不掉。
- **string/atom 键兼容**：`sget/2`(mindmap.ex:515) 已处理 dispatch 边界的 string 键，新字段照抄 `sget(a, :content)` 即可，无需额外处理。
- **既存节点向后兼容**：老快照里的 artifact 没有 `content` 键，读出来 `Map.get` 得 nil，无害；建议显式 `content: sget(a, :content)` 让所有 artifact 形状一致。

---

## 总结

1. feishu 插件**只发消息不读文档**（client.ex 仅 auth+im 端点），feishu-doc attachment **现状 = (A) 死链 ref**。
2. 「给了授权」≠ 能读：要 ① 后台开 docx 权限位 ② **每篇文档作者分享给 bot**，第②条是逐篇人工、会静默失效的权限墙。
3. **CI 关键内容仍建议 inline 存 ezagent**；feishu 可读 ref(B)即便实现也只能做展示增强，不能当 CI 判据真相源。
4. 给 artifact 加 `content` 字段**安全**：不改 core、强化单一真相源、不触任何 gate；唯一注意快照膨胀，给 content 设上限。

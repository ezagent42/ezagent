# Cinnox Autoservice MVP — ezagent 原生 UI 测试剧本

> **版本**: feat/autoservice-cinnox
> **日期**: 2026-06-02
> **核心机制**: Alice 通过 @-mention（完整 URI 格式）触发 agent，fast 先安抚（3-10s），slow 后 KB 回答（15-45s）。Admin 可一键 enable/disable 路由控制 AI 开关。

---

## 零、角色与入口

| 角色 | 登录 URI | 密码 | 浏览器 | 职责 |
|---|---|---|---|---|
| **Admin** | `entity://user/cinnox/admin` | `admin` | 窗口 A | 邀请成员、管控 route |
| **Op** | `entity://user/cinnox/op` | `op` | 窗口 B | 人工回复 |
| **Alice** | `entity://user/cinnox/alice` | `alice` | 窗口 C（隐身） | 客户提问 |

**Server**: `http://localhost:10042`
**登录页**: `http://localhost:10042/login`

---

## 一、前置准备（Admin，不录制）

### 1.1 启动

```bash
cd /home/huangjiajia/ezagent
export DEEPSEEK_API_KEY="sk-your-deepseek-key-here"
export ANTHROPIC_MODEL="deepseek-v4-pro"
export MAX_THINKING_TOKENS="0"
mix ecto.reset
mix ezagent.demo.seed_autoservice --with-slow
mix phx.server
```

### 1.2 Admin 登录（触发 main session 创建）

1. 窗口 A 打开 `http://localhost:10042/login`
2. 输入 `entity://user/cinnox/admin`，密码 `admin`
3. 点击登录 → 自动跳转到 `/sessions`
4. **此时 `session://default/cinnox/main` 被自动创建**（页面无红色错误 banner 即成功）
5. 点击进入 `session://default/cinnox/main`

### 1.3 Admin 邀请成员（在 session 内操作）

在 session 界面右侧/顶部的成员区域，找到 **Invite** 或 **Add member** 入口，依次输入以下 URI 并确认：

| 步骤 | 输入 URI | 说明 | 验证 |
|---|---|---|---|
| 1.3a | `entity://agent/cinnox/curl_fast-alice` | Fast agent（安抚响应） | 出现在成员列表 |
| 1.3b | `entity://agent/cinnox/cc_slow-alice` | Slow agent（KB 知识库） | 出现在成员列表 |
| 1.3c | `entity://user/cinnox/alice` | 客户 | 出现在成员列表 |
| 1.3d | `entity://user/cinnox/op` | 人工客服 | 出现在成员列表 |

> **邀请后确认**: 成员列表显示 5 个成员 — admin、curl_fast-alice、cc_slow-alice、alice、op
>
> **如果 invite 失败**: 检查成员是否已在列表中（可能 seed 已自动加入），跳过即可。

### 1.4 路由说明（@-mention 机制）

ezagent 使用 **@-mention 路由**（需完整 URI 格式）：`@entity://agent/<ws>/<name>`。
- Alice 发送: `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice <消息>` → 两个 agent 都收到
- Fast agent 秒级安抚 → Slow agent KB 深度回答
- Admin 可通过 Routing 面板 enable/disable MentionRouting 规则

---

## 二、录制剧本

> **路由机制**: Alice 通过 @-mention 触发 agent（`@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice`），fast 秒级安抚，slow KB 深度回答

> **CINNOX 简介**: M800 Limited（香港，2007 年成立）旗下的旗舰产品——全渠道联络中心平台（语音/视频/聊天/社交媒体），覆盖 160+ 国家，提供虚拟号码(DID)、SMS、AI 客服等功能。

### Act 1 — 开场：Alice 了解 CINNOX，Fast 安抚 + Slow KB（~3min）

| # | 操作者 | 操作 | 预期 | 镜头 |
|---|---|---|---|---|
| 1.1 | Alice | 窗口 C 隐身 → 登录 `alice` / `alice` | 登录成功 | 登录流程 |
| 1.2 | Alice | 进入 main session | 看到 5 个成员 | session 界面 |
| 1.3 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 你好，想了解一下 CINNOX` | @ 高亮 | |
| 1.4 | — | 等 3-10 秒 → Fast 安抚 | **Fast: 简短安抚语** | **特写**: fast |
| 1.5 | — | 等 15-45 秒 → Slow KB | **Slow: CINNOX 平台概述（全渠道联络中心）** | **特写**: KB |
| 1.6 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice CINNOX 支持哪些沟通渠道？` | | |
| 1.7 | — | Fast 安抚 → Slow: 语音/视频/聊天/社交媒体/邮件等渠道列表 | | |
| 1.8 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 能接入微信公众号和 WhatsApp 吗？` | | |
| 1.9 | — | Fast 安抚 → Slow: 社交媒体集成详情 | **特写**: 集成 |
| 1.10 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 和传统的呼叫中心有什么不同？` | | |
| 1.11 | — | Fast 安抚 → Slow: CINNOX vs 传统方案对比 | | |

> **旁白**: Alice 从零了解 CINNOX。每轮 Fast agent 秒级安抚，Slow agent 从 KB 调取渠道支持、社交集成、与传统方案的对比等信息。

---

### Act 2 — 深入：套餐、价格、部署（~3min）

| # | 操作者 | 操作 | 预期 | 镜头 |
|---|---|---|---|---|
| 2.1 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice CINNOX 有哪些套餐？价格怎么样？` | | |
| 2.2 | — | Fast 安抚 → Slow: 套餐结构 + 定价（KB） | **特写**: 价格 |
| 2.3 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 有没有免费试用？能用多久？` | | |
| 2.4 | — | Fast 安抚 → Slow: 试用政策（KB） | | |
| 2.5 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 部署需要多长时间？要不要技术人员配合？` | | |
| 2.6 | — | Fast 安抚 → Slow: 部署流程和周期（KB） | | |
| 2.7 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 支持私有化部署吗？数据安全方面呢？` | | |
| 2.8 | — | Fast 安抚 → Slow: SaaS + 私有化方案、安全合规（KB） | | |

> **旁白**: 从套餐定价到部署方式、数据安全，Slow agent 每次调用 KB 给出具体答案。

---

### Act 3 — Op 人工介入 + Admin Route 管控（~3min）

| # | 操作者 | 操作 | 预期 | 镜头 |
|---|---|---|---|---|
| 3.1 | Op | 窗口 B → 登录 `op` / `op` | 登录成功 | |
| 3.2 | Op | 进入 main session | 看到完整对话历史 | op 视角 |
| 3.3 | Op | `@alice 你好 Alice，我是人工客服。看了你的问题，有需要补充的吗？` | @ 提醒送达 | **特写**: @ |
| 3.4 | Alice | `谢谢！我刚才问了套餐和部署，企业版有没有年付优惠？` | | |
| 3.5 | Op | `@alice 有的，年付可以申请折扣。具体我可以帮您对接销售` | 人工回复 | |
| 3.6 | — | Fast 安抚 → Slow: 优惠政策补充（KB） | AI + 人工并行 | |
| 3.7 | Admin | 窗口 A → Routing 面板 → **Disable** AI 路由 | 规则变灰 | **特写**: disable |
| 3.8 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice CINNOX 支持哪些国家的虚拟号码？` | | |
| 3.9 | — | 等 10 秒 | **Fast/Slow 均不回复** | **特写**: 静默 |
| 3.10 | Op | `@alice CINNOX 覆盖 160+ 国家，主要市场包括香港、新加坡、英国、美国等` | Op 接管 | |
| 3.11 | Alice | `好的谢谢！你们的服务覆盖很广` | | |
| 3.12 | Admin | Routing → **Enable** | | **特写**: enable |
| 3.13 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice DID 号码多久能开通？` | | |
| 3.14 | — | Fast 安抚 + Slow KB 恢复 | AI 恢复 | **特写**: 恢复 |

> **旁白**: Op @-mention 客户插入人工回复，与 AI 并行服务。Admin 一键 disable 路由后 AI 静默，Op 完全接管。Enable 后 AI 恢复。

---

### Act 4 — DID/语音细节 + 规则粒度控制（~2min）

| # | 操作者 | 操作 | 预期 | 镜头 |
|---|---|---|---|---|
| 4.1 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 虚拟号码怎么收费？不同国家价格一样吗？` | | |
| 4.2 | — | Fast 安抚 → Slow: DID 费率详情（KB） | **特写**: KB 深度 | |
| 4.3 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 如果客户在国外，通话质量怎么保证？` | | |
| 4.4 | — | Fast 安抚 → Slow: 全球基础设施和 QoS（KB） | | |
| 4.5 | Admin | Routing → Disable slow → 仅保留 fast | 只剩安抚 | **特写**: 粒度 |
| 4.6 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 有没有实时监控和报表功能？` | | |
| 4.7 | — | Fast 安抚（无 KB 详情） | 仅安抚 | 对比 |
| 4.8 | Admin | Enable slow | 恢复 | |
| 4.9 | Alice | `@entity://agent/cinnox/curl_fast-alice @entity://agent/cinnox/cc_slow-alice 谢谢你，帮我总结下 CINNOX 最核心的优势` | | |
| 4.10 | — | Fast 安抚 → Slow: 核心优势总结（KB） | 收尾 | 全景 |

> **旁白**: Slow agent 的 KB 回答 DID 费率、QoS、监控报表等专业问题。Admin 精细控制路由粒度。所有管控即时生效。

---

## 三、快速重启

```bash
pkill -f "mix phx.server"
cd /home/huangjiajia/ezagent
export DEEPSEEK_API_KEY="sk-your-deepseek-key-here"
export ANTHROPIC_MODEL="deepseek-v4-pro"
export MAX_THINKING_TOKENS="0"
mix ecto.reset
mix ezagent.demo.seed_autoservice --with-slow
mix phx.server
```

## 四、环境

| 项目 | 值 |
|---|---|
| 分支 | `feat/autoservice-cinnox` |
| Ezagent 路径 | `/home/huangjiajia/ezagent` |
| Server | `http://localhost:10042` |
| Fast agent | curl + DeepSeek (`deepseek-chat`) |
| Slow agent | cc + DeepSeek Pro (`deepseek-v4-pro`) + KB MCP |
| KB 文件 | `priv/cinnox/kb/kb.db` |
| 安抚语 prompt | `CinnoxAssets.build_fast_ack_prompt/0` |

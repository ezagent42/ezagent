# docs/loom/ 文档时间线 + 有效性标注

11 份文档按时间叠加，设计 pivot 过几轮。**读任何一份之前先看这张表**，
免得按已推翻的设计写代码。

图例：✅ 现行有效 ｜ ⚠️ 部分有效（标注哪部分） ｜ 🗄️ 历史记录（看动机，别照做）

| 文档 | 日期 | 状态 | 说明 |
|---|---|---|---|
| `PRD.md` | 05-27 | 🗄️ | "Hello" demo 的产品论证。**产品动机仍是最好的入门读物**（为什么要多 agent 编排 demo），但实现形态（hello plugin、req/resp 反例分析）已成历史。 |
| `docs/superpowers/specs/2026-05-28-plugin-loom.zh_cn.md` | 05-28 | 🗄️ | schema-driven page-builder 设计（41 预制组件 + JSON Patch）。**这条路线没有实现**——实际走了 vendored ai-ui-builder + AI 生成 JSX + Sandpack。只读"是什么/不是什么"一节校准定位。 |
| `HELLO_REFERENCE.md` | — | 🗄️ | hello plugin 时代的参考，纯历史。 |
| `TEMPLATE_DESIGN.md` | — | ⚠️ | 模板体系设计；Class 级动态生成的思路有效，细节以 `saved_classes.ex` 代码为准。 |
| `2026-05-29-frontend-plugin-integration.md` | 05-29 | ✅ | `forward "/loom"` 唯一触碰模式 + WebPlug 职责——现行接入方式的权威论证。 |
| `2026-05-29-loom-sdk-bridge.md` | 05-29 | ✅ | sandbox ↔ host ↔ 服务端的 postMessage 桥设计。 |
| `FRONTEND_DIST_PLAN.md` | — | ⚠️ | 抽 SDK → dist → vendor 的六阶段计划，已执行完。**Phase 6 的 vendor 流程仍是现行操作**；文中路径写的还是 `ezagent_plugin_hello`，按 loom 替换理解。 |
| `SDK.md` | — | ✅ | SDK v1 形状（API 契约）。 |
| `sdk-v2-additions.md` | — | ✅ | SDK v2 四能力 + 端到端 curl 验证 + 加 tool/preset 步骤——SDK 的现行权威。 |
| `2026-06-01-loom-as-session-redesign.md` | 06-01 | ✅ | session-rooted 重设计：v0worker、page_update span、mention 解析。**现行编排形态的奠基文档**。 |
| `2026-06-05-shareable-snapshots-and-fork.md` | 06-05 | ✅ | 分享快照 + fork 两阶段设计。 |
| `2026-06-08-loom-data-lifecycle.md` | 06-08 | ⚠️ | 数据全生命周期（阶段 0-7），**最接近现状的全景文档**。唯一漂移：写的"四个旁路 JSON"，06-09 加了第五个 `loom_knowledge.json`（见 persistence-map.md）。 |
| `2026-06-08-loom-to-socialware-migration.md` | 06-08 | ⚠️ | 迁移处置清单。**在 `docs/loom-socialware-migration` 分支上，feat/loom 本体没有这个文件**。处置方向仍有效，但 phase 状态已漂移（P4 已在 main 落地且实现路线有出入）——修正见本 skill 的 `migration-map.md`。 |

## 未成文变更（代码已变、docs/loom 没跟上）

- **06-10/11 Stitch 重构**：Stitch/AiSpot 从 WebPlug 直连 DeepSeek 改为
  `loomstitch_<sid>` worker（对话进 MessageStore）、consumer_session 标记、
  session-less `POST /intent`、publish self-heal。**没有 docs/loom 设计文档**，
  权威是代码 + `loom-developer` skill（同在 feat/loom，`.claude/skills/loom-developer/`）。
  06-05 snapshots 文档与 06-08 data-lifecycle 文档里关于 Stitch 持久化的描述
  （`loom_stitch_chats.json`）相应过时。

## 相关 skill

- **`loom-developer`**（06-11 起，feat/loom）：开发者向——backend-map / 前端与
  SDK / gotchas / recipes。写代码用它；本 skill 管介绍、考古、迁移。

## 维护约定

新设计文档落 `docs/loom/`（日期前缀），同时更新本表 + 受影响 reference。
被推翻的文档**不删**（演化记录有考古价值），改本表状态即可。
代码先行、文档未跟上的变更，记进上面"未成文变更"一节。

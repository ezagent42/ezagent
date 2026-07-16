# 企业自助开通 workspace:功能缺口清单(SaaS 形态)

> 2026-07-16。来源:2026-07-15 冷启动实测(全新企业用户、仅浏览器,
> 本地隔离实例 @ eb2b56a88)+ 静态代码核查。形态前提:SaaS 托管共享实例,
> workspace 分租户(`docs/notes/workspace-as-deployment-unit.md`);
> 企业用户只接触浏览器面。

## 已验证可自助的部分(不在缺口内)

- 注册表单→founder 自动获得专属 workspace(`registration.ex:257-272`),中文界面完整;
- `/sessions` 建会话 + 选模板一键 materialize 成员 agent、聊天、页面预览、公开页链接;
- 消息路由与回复闭环;匿名访客公开页(`/socialware/external?session_uri=…`)200。

## 缺口清单(按建议交付顺序)

### P0 —— 硬闸门(不拆则随机企业无法走完第一步)

| # | 缺口 | 现状证据 | 需要什么 |
|---|---|---|---|
| G1 | **注册开关无 UI** | `registration_open` 默认 false(`app_settings.ex:97-98`);关门页只有"当前未开放注册。"无任何出口(`registration_controller.ex:28-39`);`/admin/settings` 仅 SMTP(`admin_data.ex:86-118`) | admin UI 加 `registration_open`/`registration_require_invite` 开关;关门页给申请入口 |
| G2 | **邀请码仅 CLI** | `mix ezagent.invite mint/list/revoke`(`mix/tasks/ezagent.invite.ex`),无界面 | admin UI 包皮(后端已完整) |
| G3 | **workspace 显式创建无 UI** | world 无 `workspace.create` action(`workspace_plugin_actions.ex:39-44`);只能 mix task 或注册副产品 | 视产品决策:开放 UI 创建或明确"一注册一租户" |
| G4 | **founder 无权自配 agent API key** | `agent.api_key.put` UI 存在(`world_live.ex:263-266`)但 founder 在自己 workspace 的 agent Keys 页得 `:unauthorized`(实测) | cap 授予路径修复;依赖 agent 授权模型收口(`docs/notes/2026-07-10-agent-authorization-roadmap.md`,`docs/futures/todo.md` 头号项) |
| G5 | **缺 key 失败态不可行动** | 无 key 时 agent 仅回复通用道歉文案,零"缺什么/去哪配"提示;`credential_status` 仅 owner+ws-admin 可见(`identity_data.ex:306,619`) | 失败回复显式化 + 跳转配置;key 填入即时校验反馈 |
| G0 | (运营侧,不计入企业自助)bootstrap 断点 | `mix ezagent.home.init` 独立运行崩溃(`socialware_seed.ex:72` 依赖未启动的 scheme registry ETS);近期新增的两个必需启动 secret 未入 onboarding 文档,缺失时报错不指向修复 | 修 bug + env 校验 fail-fast + 文档收录 |

### P1 —— 可发现性与可恢复性

| # | 缺口 | 现状证据 |
|---|---|---|
| G6 | UI 可读性:agent 列表裸 UUID(用户无法识别哪个 agent 需要配置,唯一线索是 flavor 列);首登 PAT interstitial 对普通用户是噪音;登录后 Continue 落 404 死路页;会话名校验文案与实际规则矛盾(称可用中文但纯中文名被拒);错误裸 atom 直出 UI | 实测 + `world_live.ex` 渲染链 |
| G7 | onboarding 向导与应用 gallery 缺失:注册后无引导;socialware 发现面未产品化(`DefinitionRegistry.list/1` 有 API 无前端面);dev/prod manifest 可见性不一致(`config.exs:29` prod-only 扫描) | 注册后向导:选模板→配 key→发首条消息→看公开页 |

### P2 —— 业务闭环与防回退

| # | 缺口 | 现状证据 |
|---|---|---|
| G8 | 企业资料/KB 导入无 UI:`kb.ingest` 仅 action/MCP(`behavior/kb.ex:54`),逐条、无批量、无上传界面 | 无 UI 通道则真业务应用只能跑 demo 数据 |
| G9 | 面向企业用户的产品文档为零:`docs/guide/` 全部面向运营/开发(含 IEx/mix 命令) | 需"第一天上手"+常见错误自助手册 |
| G10 | 无浏览器级 E2E 锁定冷启动链:CI 全为 ExUnit+markdown 剧本 | 把"注册→装模板→配 key→出结果→错误恢复→公开页"整链脚本化进 CI,防闸门被后续 PR 焊回 |

## 明确不在本清单(单企业自助不需要)

组织/中枢-成员层级、per-企业三方(飞书/邮箱)凭证、计费/配额、运营
dashboard、self-host 自助安装器——分别归中枢客户交付、商业化、稳定性
轨道;其中授权相关项等 G4 的模型定型后再动,避免返工。

## 验收方式

每阶段收口后**重跑冷启动实测**(P2 的 G10 将其自动化):度量"随机企业
不靠工程师能走到第几步"。自动化测试通过 ≠ 用户可自助——两者是不同的轴。

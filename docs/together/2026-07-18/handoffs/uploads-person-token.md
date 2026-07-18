# Handoff: uploads person-token + 读面对齐(core+web infra,原 PR-C)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** an independent developer
> **Tracking:** 开工单 v2 终版 infra 清单 #4 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** brainstormed —— **过 Allen 后开工**(动 core 授权载体;论证段已备好:`docs/notes/2026-07-18-attachment-x-model.md` §三)

## 0. Mission
kanban 节点附件点开 forbidden(㊲)。根因不在 kanban 传参,在 uploads 通用层:serve-time 授权是 **chat-message 参与本位**,非-chat 消费面(kanban 板 artifact)恒拒。修法 = `DownloadToken` 加可选 person 绑定(`grantee` + `host_uri` hint),`UploadsController` 加 person-bound 授权分支;附带 chat 侧现签补权 + stale 注释修正。

## 1. Required reading
1. Skill `ezagent-developer`。
2. `docs/notes/2026-07-18-attachment-x-model.md`(㊲ 模型定案,§一-§五全链查验;§三=给 Allen 的论证段)。
3. `docs/notes/2026-07-17-xy-review.md` §2(两个独立根因)。

## 2. Locked decisions
| # | Decision | Value |
|---|----------|-------|
| 1 | 复查不能删只能替代 | serve-time 第二道复查是 codex HIGH 防泄漏要求;person-bound 是**更强**替代(泄漏 token 换人无效) |
| 2 | 向后兼容 | 新字段可选:旧 token(无 grantee)走旧 chat 复查分支,零 breaking |
| 3 | kanban 侧分工 | 点击现签(`kanban.download_artifact` fresh href)归 PR-K,已可先落;grantee 传参在本 PR 合后 PR-K 补一行 |

## 3. 现象/原因(现读锚点)
- **现象**:板节点附件 → 打开 → forbidden;非 admin 连上传者本人都被拒;tab 停留 >5min 再点必 `:expired`(渲染成同一 forbidden)。
- **根因 1(主)**:`UploadsController.download/2` 验签之外的第二道复查 `authorized?/2`(uploads_controller.ex:93,:110-116)= admin ∪ 上传消息 sender ∪ 附件所路由 session 参与者——**全查 Message 表**(`caller_in_attaching_messages?` :133-157,按 body LIKE 找带 attachment 的消息行)。kanban 附件经 `attach_upload` 直写板 `:kanban` slice artifact(kanban world_actions.ex:330-343),**不产生 Message** ⟹ 复查恒 false。
- **根因 2(次)**:`DownloadToken` 是 URI-bound 纯签名器,payload 只有 uri/issued_at/ttl(download_token.ex:115-119,**无 receiver 参数**——「传错 receiver」机制上不成立);`mint!(uri)` 在渲染时预签(kanban world_data.ex:406),默认 TTL 300s(:61)。
- **顺手项**:`resolver.ex:238-241` stale 注释(「per-message 铸 receive cap」是 A2.2 前旧说法);chat 侧现签处补 `Membership.authorize/3` 对齐读面。

## 4. Design & plan
单 PR 两半:
1. **core**:`DownloadToken` payload 加可选 `grantee`(person 绑定)+ `host_uri`(宿主 hint),签进 payload;mint 侧姿势不变(授权后才签——渲染/现签前已过 read_ctx cap 门)。
2. **web**:`UploadsController.authorized?/2` 加分支——token 带 grantee 时校验 `caller == grantee` 即放行(替代 chat 复查);无 grantee 走旧路。chat 侧现签补 `Membership.authorize/3`;修 resolver stale 注释。

## 5. Definition of Done
- [ ] person-bound token:caller==grantee 放行、caller≠grantee 拒(controller 测试,含「泄漏 token 换人无效」反例)
- [ ] 旧 token(无 grantee)行为逐字节不变(现有 uploads_controller_test/download_token_test 零回归)
- [ ] 非-chat 消费面端到端:kanban 附件(无 Message)经 person token 可下载——E2E 请求真打 `/uploads` 路由返回 200(消费侧 fresh-href 联测在 PR-K 勾,这里登记 parity 项)
- [ ] `resolver.ex:238-241` 注释与 A2.2 现实一致(doc.scan 过)
- [ ] All gates green(arch.scan/doc.scan/uri_query.scan/check_invariants/format/test/:ezagent_plugin_check)
- [ ] CI green + rebased on `main`

## 6. Discuss-first vs Deferred
**Discuss-first(开工闸):** Allen 过目 §三论证(core 授权载体加字段);`host_uri` 是否本轮就消费(还是只签不读,留扩展)。
**Deferred(已挂遗留表):** 内部会话页读史零判定(observer 全可读,与外部面倒挂,attachment-x-model §5.3)——另立项,不阻塞。
**Never deferred:** 决策 1(复查只替代不删)。

## 7. Conflict-avoidance / 8. Merge model / 9. LOC
文件面:core `uploads/download_token.ex` + web `uploads_controller.ex`(+resolver 注释);与 PR-K 约定单行接口(mint 传 grantee)。独立分支 PR → `main` Allen 审。估 ~100-180 LOC。开放问题见 §6。

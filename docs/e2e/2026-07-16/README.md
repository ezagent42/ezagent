# kanban collab 改版 e2e（2026-07-16，两账号真 UI，非 admin）

**环境**：fresh dev DB（`ecto.reset`，新 EZAGENT_SIGNING_SEED_V1 + EZAGENT_PAT_PEPPER_V1）；kanban 经治理路发布（recipes.yaml seed + `ManifestYaml.import`，dev 无 boot scan）；两个**普通账号**（owner@test.local / viewer@test.local）走真 UI 注册+邮箱确认+登录；**全程零 admin 代操作**（admin 只做 operator 职能：开注册、设首密——产品文档化路径）。

## 走通的完整链（截图序）

| # | 截图 | 验证点 |
|---|---|---|
| s01 | login-page | 登录页 |
| s02 | admin-pat-page | 登录成功→一次性 PAT 页（#1361 versioned PAT） |
| s04 | admin-world-home | world UI 挂载（admin，operator 职能） |
| s05-s07 | register/confirmed | **owner 真 UI 注册** + Swoosh 确认信链接确认 |
| s08 | owner-world-home | owner 登录进自己 workspace（owner-c9f54a） |
| s09-s10 | wizard | 新建会话向导：**「Kanban 看板团队」在应用列表**（发布/发现 ✓）+ 两 role 槽 |
| s11 | session-created | 会话创建（**发现 bug：cc-headless 无凭证源→角色静默跳过，UI 无提示**） |
| s13 | native-flavors | 向导 Flavor 覆盖 native → 三成员齐（assistant 物化 ✓） |
| s14 | room2-conversation | **⑤ 验证：非 admin owner 看到「看板」tab**（installer render cap） |
| s15 | kanban-tab-empty | T6 空 tab 建首板入口 |
| s19 | kanban-tab | 看板列表 + **去gh UI：板侧无任何 token 登记**（decision2 ✓） |
| s20 | roadmap-created | **⑥⑧ 验证：普通成员（零 create_agent cap）建板成功**（rule-authority + 双钥匙：owner 20 caps + 挂载表 2 行） |
| s23 | root-created | **H1 验证：建根自动认领**（canvas 节点带 @owner + 定位 stage） |
| s24/s27 | node-panel | **collab 节点面板全景**：claimed@owner(我)/取消认领 toggle/状态+阶段编辑/产物纯数据/删除(含子树)/drop（规则3/4/5 UI） |
| s25 后 | (log) | **加子自动认领**（需求梳理@owner，继承父 stage） |
| s28 | share-dialog | **规则7 分享**：「任何拿到此链接的人都能**只读**查看（7天有效）」+ receive 链接 |
| s29 | receive-result | **viewer 点链接→302 到自己 session**（服务端解析接收 session） |
| s30 | (erpc) | **跨 workspace 只读挂载坐实**：owner 板 → viewer assistant，`access=read`，actions 仅 `[get_tree, export_markmap]`（H4 链接恒只读 ✓） |

## e2e 挖出的 bug（已修/已记）

- **⑨ Mount.provision 5s 超时孤儿板**（已修 `mount.ex` deadline 30s）：冷建 agent 6.6s > 默认 5s call → with 链半途崩 → agent 建成但零钥匙零挂载行（demo-board 即孤儿实证）。
- **⑩ cc-headless 角色静默跳过**（记录）：无凭证源时 install 跳过角色仅 server log 报 error，**UI 无提示**（向导直接收起，用户不知道 assistant 没物化）。归 UX/install 面。
- **⑪ dev 无 socialware 发布车道**（记录）：`socialware_manifest_boot_scan` prod-only；dev 手动 import 撞运行中 server 的 _build 锁（mix task 编译冲突），要走 erpc 进运行节点用 `ManifestYaml.import`。dev 体验债。
- **⑫ 建会话向导「创建」按钮在折叠线下**（UX）：不 scroll 看不见/点不到（agent-browser 空点了三次才定位到）。
- **⑬ dev 前端易骨架屏**（dev-env）：server 重启后 vite 冷启动 + WS 退 longpoll（106:4），world React 挂载偶发失败/极慢，重开浏览器或多次刷新恢复。viewer 侧 UI 截图因此缺（机制已由挂载行+钥匙实证）。

## 未在 UI 逐步截图、由测试覆盖的语义

退领需空（`:has_content_cannot_unclaim`）/重认领/单根 `:root_exists`/drop 混合归属挡+版主兜底——`kanban_test.exs` 33 例全绿（b63d1f400）；前端接线与已证的 add_node/建板同一条 onAction→world:dispatch 路。

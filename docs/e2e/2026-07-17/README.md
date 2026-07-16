# kanban collab round2 针对性 e2e 验证(2026-07-17,真 UI agent-browser)

- 环境:worktree kanban-progress-board @ `feat/kanban-collab-round2`(d5655c715),dev server localhost:10042,world UI http://world.localhost:10042,账号 owner@test.local。
- 现场:Owner-Room2 会话(roadmap/test-0716/demo-board 三块板,demo-board 为孤儿板)。
- 每张图对应一个 round2 修复项(文件名=项号),逐张人工自审(Read 看图)后写结论。

| 项 | 验证点 | 截图 | 结论 |
|---|---|---|---|
| r01 | ㉗ 面板新布局(无本图配置块㉓/名称就地编辑㉖/一排一信息/产物区「添加」+下拉 链接·内容·画图·附件/无「✓已保存」㉞) | r01-panel-spec.png | **过**:图见 节点属性 面板——名称输入框、状态/阶段/产物各一排、产物(0)+「添加 链接▾ +添加」、删除(含子树)/drop 两入口;无配置块、无「已保存」 |
| r02 | ㉕ drop=跟踪标记:认领节点 drop(prompt 理由)→红框+面板理由 | r02-drop-red.png | **过**:「需求梳理」画布红框;面板「已 drop:北极星指标不达标(跟踪标记,节点保留)」+理由「e2e验证:北极星指标未达标」+drop 历史(1);节点未删;服务端 `kanban.drop_subtree` authz=granted(reason 入参可查 server log) |
| r03 | ⑲ 导图列表版主删板入口+确认弹窗,真删 demo-board | r03-delete-board.png + r03b-delete-result.png | **过**:r03 见三块板旁垃圾桶删钮(title=「删除看板…退休板 agent+清挂载,不可恢复」);确认框为**原生 window.confirm**(CDP 截图截不到原生框,弹窗文本由 CLI 捕获:「删除看板「demo-board」?板 agent 将退休、所有会话里的挂载会被清掉,不可恢复。」);accept 后 `kanban.delete_board` dispatch,r03b 列表只剩 roadmap/test-0716——真删成功 |
| r04 | ㉙ 点分享→两选项框 | r04-share-two-options.png | **过**:「分享看板」modal 两选项——「分享到会话」(气泡发进 chat)/「复制分享链接」(只读,7 天有效)+链接输入框。注:modal 依赖 share_board 回推 share_link,弹出有 1-2s 延迟 |
| r05 | ㉙ 「分享到会话」→chat 出看板气泡 | r05-share-to-session.png | **过**:chat 见气泡【看板分享】看板「roadmap」+「加入我的看板」按钮 |
| r06 | ㉝ 分享链接粘贴发进 chat→自动渲成气泡非裸链接 | r06-unfurl.png | **过**:粘贴 `/socialware/kanban/receive?token=…` 纯文本发送,渲成「看板分享」气泡(与 r05 同形态,UNFURL_RENDERERS 命中),非裸链接 |
| r07 | ⑱ 深色主题下看板面不刺眼 | r07-dark-kanban.png | **过**:用户菜单「Dark mode」真开关(`data-theme=dark`);看板面整体深色——画布深底点阵、侧栏/面板深卡、节点框对比可读,无大片白底刺眼。残留小瑕:画布左下 zoom 控件仍白底小块(记入下轮) |
| r08 | ⑳ 无 assistant 会话(Owner-Room)看板 tab 建板成功 | r08-no-assistant-create.png | **过(带残留)**:Owner-Room(1 成员,无 assistant)填「新导图名=r08-board」点 +,server log `kanban.create` 走 create_board 全链成功(board agent + 建板人 per-action operate 钥匙全铸,`cap_granted`×20 动作);图见列表含 r08-board+版主删钮。**残留**:建板后 6s 内本人列表未自刷,切换会话回来才见——㉒-① 推送环对「建板」事件仍有缺口(节点写动作已覆盖,见 r09),如实记 |
| r09 | ㉘/㉒-① 推送环:双浏览器 A 加节点,B 不刷新 3s 内自动出现 | r09-push-refresh.png | **过**:双浏览器同账号两个独立 LiveView socket(editor 密码不可用;viewer 在别的会话收不到本会话 topic,机制上本就不该收到——broadcast 面向同会话成员);A 在 roadmap 给根节点加子「r09-push-node」,B **零刷新** 3s 内画布自动出现该节点(图右下),`:kanban_changed` 推送环闭环 |

## 结果汇总

- **9 项全过,0 SKIP**;2 个残留如实记:①r07 zoom 控件白底小块(⑱ 收尾);②r08 建板事件不触发本人列表自刷(㉒-① 对 create 场景的缺口,节点写动作场景已闭环)。
- r09 的「双账号」降级为「同账号双浏览器」:editor 密码不可用,viewer 是跨会话只读方(收不到本会话 topic 属设计内);推送环验证点=「非操作方 socket 零刷新自更新」,同账号双 socket 等价成立。

## 备注

- r03 的「确认弹窗」是原生 confirm,非自定义 modal——e2e 证据形态=CLI 捕获的弹窗文本+删除结果图(方法摩擦已记 return 文档)。
- 用户菜单有「Dark mode」入口(r07 走真 UI 开关,非 eval 注入)。

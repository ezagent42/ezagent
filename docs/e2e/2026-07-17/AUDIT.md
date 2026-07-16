# kanban 协作改版 ㉞ 项审计对照表(2026-07-17,给下轮手测用)

> 来源:`docs/notes/2026-07-15-kanban-layering-debt.md` ⑤-㉞ 全量逐项。
> 状态口径:**✅本轮修**(round2,分支 feat/kanban-collab-round2 16 commits)/ **✅上轮已修**(⑤⑥⑦⑧⑨)/
> **🔨handoff中**(zyli #1443 world 前端 / gaga #1444 agent runtime)/ **⏸等Allen决策**(#1442 D1-D6)/ **📋规划中**(后续独立 PR)。
> 本轮验证截图见同目录 `README.md`(r01-r09)。

| 项 | 一句话 | 状态 | 谁/哪个PR | 下轮你要测什么 |
|---|---|---|---|---|
| ⑤ | 装 kanban 后 owner 看不到看板 tab(render cap 没授 installer) | ✅上轮已修(installer 部分) | 我方,`Installation.grant_installer_view_caps`;成员 join 补发 ⏸D1 | 新账号建会话装 kanban → 不用 admin 直接见「看板」tab |
| ⑥ | installer 无 create_agent cap,UI 建不了板 | ✅上轮已修(过渡 rule);永久收敛 ⏸D2 | 我方 `{:rule,:socialware_runtime_provision}` 过渡;Allen #1442 D2 拍三选项 | 普通用户在装了 kanban 的会话填新导图名点「+」→ 板建出来 |
| ⑦ | board owner 建不了根节点(只认 admin wildcard) | ✅上轮已修 | 我方,behavior 层 `board_admin?`(版主=data_owner) | 普通用户在自己的板上直接建根节点成功 |
| ⑧ | owner 建板只拿 Manage cap 没拿 Kanban operate cap,读写全 unauthorized | ✅上轮已修(create_board 路) | 我方,`BoardProvision.create_board` 给建板人经 Mount 发全动作钥匙 | 建板后不刷新直接加节点/改名都成功(无 unauthorized) |
| ⑨ | Mount.provision 5s 超时半途崩出孤儿板 | ✅上轮已修 | 我方,deadline 30s(ff8d44b44) | 连建 3 块板无一失败/无孤儿(孤儿=列表有板但零钥匙) |
| ⑩ | cc 凭证缺失时 install 静默跳过 assistant,无 UI 提示 | 🔨handoff中 | gaga #1444(凭证供给面)+ zyli #1443(向导投影) | 无凭证装 kanban → 向导/会话面有明确「缺凭证」提示与补供给入口 |
| ⑪ | dev 无 socialware 发布车道(boot scan prod-only) | 📋规划中(RPC import 小 PR);口径变更 ⏸D5 | 我方独立小 PR;Allen D5 拍 dev 开不开 boot scan | dev 下 `socialware.import` RPC 命令能发布 manifest 不撞 _build |
| ⑫ | 建会话向导「创建」按钮折叠线下点不到 | 🔨handoff中 | zyli #1443(SessionsTable max-height/按钮固定底) | 小窗口开建会话向导,「创建」按钮不滚动可见可点 |
| ⑬ | dev 前端骨架屏(vite 冷启 + WS 退 longpoll) | 🔨handoff中 | zyli #1443 | dev 首次加载不长挂骨架屏;WS 不再 106:4 被拒 |
| ⑭ | 跨用户协作正路=邀请码注册,缺邀请码铸造/管理面 | 🔨handoff中 | zyli #1443(邀请码管理面);add_member 接口存在性待审 | UI 能铸邀请码;新人扫码注册「出生」进目标 workspace |
| ⑮ | dev 确认信链接域名指生产 app.ezagent.chat | ✅本轮修 | 我方 e24b9b0d2(dev.exs 覆盖 verification_base_url) | dev 注册收确认信,链接是 localhost:10042 可点开 |
| ⑯ | 分享的 workspace 口径:转发路有 same_workspace 守卫,链接路没有 | ⏸等Allen决策 | Allen #1442 D4(用户倾向:系统支撑就放开) | D4 拍板后:跨 ws 粘分享链接,行为与拍板口径一致 |
| ⑰ | 成员变动无实时推送(被加者界面不自刷) | 🔨handoff中 | zyli #1443(订阅/分发基建)+ 我方推送环发布侧 PR2 | A 把 B 加进会话,B 不刷新自动见新会话/成员 |
| ⑱ | 深色主题下会话/看板面硬编码浅色刺眼 | ✅本轮修(kanban 半,20ba01122);Conversation 层 🔨zyli | 我方 Kanban/KanbanCanvas token 化;zyli #1443 Conversation.tsx | 深色下看板面无白底刺眼块(r07);对话面同验(zyli 侧) |
| ⑲ | 无删板 UI/孤儿板无清理路 | ✅本轮修 | 我方 79f0cdd24(delete_board 动作:retire+清挂载)+ 50cf5e513(列表删钮+确认框) | 版主在导图列表点垃圾桶→确认→板消失(r03);非版主不见删钮 |
| ⑳ | 建板把 assistant 钥匙做成硬前置,无 assistant 的会话建板 fail | ✅本轮修 | 我方 772b64215(降级为增强:主链=宿主+建板人钥匙,assistant 有则附加) | 无 assistant 会话建板成功(r08);有 assistant 会话 assistant 也拿钥匙 |
| ㉑ | 「未装载:缺凭证」横幅持久不随 reconcile 刷新 | 🔨handoff中 | gaga #1444(上游供给)+ zyli #1443(投影读侧) | 补凭证/补物化后横幅消失或变已装载 |
| ㉒ | 建板后本人不自动刷出新板+刷新丢 tab 态 | ①推送环 ✅本轮修(7120b147f);②tab 深链 🔨zyli | 我方 :kanban_changed 广播;zyli #1443 view 深链 | 建板不刷新自动见新板;刷新页面仍停在看板 tab(zyli 侧) |
| ㉓ | 板侧边栏「本图配置」块应整体移除 | ✅本轮修(吸收进㉗) | 我方 889e84f9c | 面板无 GitHub 仓库/Miro 持久配置块(r01);Miro 板名只在导出弹窗填 |
| ㉔ | (被㉕取代)删除与 drop 合并 | — 已被㉕改记取代 | — | 无需测 |
| ㉕ | drop 重定义=北极星不达标跟踪标记(标红不删) | ✅本轮修 | 我方 1d9243257(behavior 非破坏标记+理由)+ 9e810572c(红框+面板理由) | 对自己认领节点 drop 填理由→节点红框、子树保留、面板见理由/历史(r02) |
| ㉖ | 节点名称无就地编辑,改名藏 prompt;节点框名字截断 | ✅本轮修(就地编辑,吸收进㉗) | 我方 889e84f9c;画布节点框自适应宽度部分见㉗ | 面板顶部名称输入框直接改名回车生效(r01) |
| ㉗ | 节点属性面板布局按规格重做 | ✅本轮修 | 我方 889e84f9c(一排一信息/产物区「添加」+下拉 链接·内容·画图·附件/每产物删钮/内容 md 大框) | 逐条对 r01:无配置块、下拉四选项、产物可删、「内容」弹 md 编辑框 |
| ㉘ | 看板操作不向同会话其他成员广播 | ✅本轮修(kanban 半,7120b147f);基建半边 🔨zyli | 我方写动作成功广播 :kanban_changed+画布自刷 | 双浏览器 A 加节点 B 不刷新 3s 内自动出现(r09) |
| ㉙ | 分享应两选项:分享到会话(气泡)/复制链接 | ✅本轮修 | 我方 657ec1c5c | 点分享见两选项(r04);「分享到会话」chat 出看板气泡(r05) |
| ㉚ | 「复制链接」没真复制还谎报已复制 | ✅本轮修 | 我方 657ec1c5c(copyTextRobust 回退+真实成败反馈) | http://<IP> 访问点复制→成功才提示已复制,失败提示手动复制 |
| ㉛ | session-template 与 sw 解绑,缺「安装 socialware」面 | 🔨handoff中 | zyli #1443(装/卸 sw 面+存模板) | 已存在会话可后装 sw;配置可存成 template 复用 |
| ㉜ | kanban tab 应 plugin 级恒显(门控内容不门控 tab) | ⏸等Allen决策 | Allen #1442 D3(倾向 a:契约不动,发钥匙面变宽) | D3 拍板后:未装 sw 的会话也见看板 tab,无钥匙=空列表/只读 |
| ㉝ | 分享链接粘进 chat 应自动渲成气泡(飞书式) | ✅本轮修(unfurl 机制+气泡);点击挂载落点修正 📋二期 | 我方 6629c1919(UNFURL_RENDERERS 注册表,kanban 首消费者) | 粘链接发送→渲成看板气泡非裸链接(r06);点「加入我的看板」挂载进本会话(二期验) |
| ㉞ | 「✓已保存」常驻假标记 | ✅本轮修(吸收进㉗,已摘除) | 我方 889e84f9c | 看板底部无常驻「已保存」(r01);失败仍有 toast |
| 债③ | 分享接收业务塞在 web controller(P13 违反) | ✅本轮修 | 我方 7f32a44a8(搬 plugin `receive_shared_board`,controller 瘦身)+ ccdce242a(收敛:receive 链不发 render cap,TODO 归 D1/D3) | 点分享链接仍能挂载进落点会话(回归) |
| 债② | kanban 数据/动作层住 world_plugin | ✅本轮修(可搬半) | 我方 d5655c715(kanban_data/kanban_actions 搬进 plugin,world 剩 @pages 注册数据);UI 注册机制 ⏸D6 | 看板 tab 全功能回归(搬迁纯移位不改行为) |
| 债① | BoardProvision 住 domain_session | ✅本轮修(默认值上提半步,fc670e009);本体搬迁 ⏸D2+D6 | 我方;Allen #1442 D6(Mount dispatch 化/折 CompositionBinding) | 无独立测点;跟 D6 走 |
| gap3/④ | cc-headless 无 MCP 桥,assistant 零看板工具 | 🔨handoff中 | gaga #1444(#1323 落 main,对齐 #1434 姿势) | @assistant「给板加个节点」→ 真 dispatch 成功板上见节点 |

## 汇总

- ✅本轮修:14 项(⑮⑲⑳㉓㉕㉖㉗㉙㉚㉝㉞ + ⑱㉒㉘ 各 kanban 半)+ 债③ + 债②(可搬半)+ 债①(半步)
- ✅上轮已修:5 项(⑤⑥⑦⑧⑨)
- 🔨handoff中:8 项(⑩⑫⑬⑭⑰㉑㉛ + gap3/④;含 ⑱㉒㉘ 的 world 半边)——zyli #1443 / gaga #1444
- ⏸等Allen决策:3 项(⑯/D4、㉜/D3、⑥永久/D2)+ 债①②永久线(D6)+ D1(join 补发前置)+ D5(⑪口径)——#1442
- 📋规划中:2 项(join 补发 PR3 等 D1;分享二期 PR4:request_edit+claim_shared 落点;⑪ RPC import 小 PR)
- ㉔ 被 ㉕ 取代,不计。

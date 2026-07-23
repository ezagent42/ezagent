# 官网 E2E 闭环 — 任务拆分 handoff

2026-07-02 · ruihua。旅程见 [`homesite-journey.zh_cn.md`](./homesite-journey.zh_cn.md)，scenario 36–39。全部 🚧，未实现的面先用空白 HTML 占位。

## 主流程（闭环）

1. 浏览官网
2. 官网对话触发登录 → 回跳官网、变已登录
3. 官网对话 = 在 world 的【官网 session】说话
4. 用户或 agent 发消息 → composer「查看当前session」按钮上红点 +1；点它进入 world 的【官网 session】
5. 分享该 session（官网或 world 都能发起）→ 别人进【同一个】session 群聊（成员、留历史）
6. 进 world → 一键复制官网 session 配置、创建【新】session → 自己当 owner（租户、无历史）

## zyli — 官网 & hello 前端（承接自 zhaomato，2026-07-16 退出）

| # | 任务 | 依赖 |
|---|---|---|
| H1 | 去掉底部 composer 的「选择」按钮 | — |
| H2 | 加「查看当前session」按钮：点击深链进入本页面对应的 world session | W2 |
| H3 | 该按钮的红点数字：官网 session 每多一条消息（用户**或** agent）+1；进 world 查看后清零 | W3 |
| H4 | 加「分享」按钮：分享当前 session（产出分享链接） | W4 |
| H5 | composer 发送真正写入官网 session（scenario 37 出站前端侧） | 后端写入路径 |

## zyli — world 后端 / 前端

| # | 任务 | 被依赖 |
|---|---|---|
| W1 | 某 session 内：一键复制当前 session 配置、创建新 session（操作者成 owner、无历史） | scenario 39 |
| W2 | 接受外部深链：打开指定 session（官网「查看当前session」的跳转目标） | H2 |
| W3 | 向官网推送某 session 的新消息计数（红点数据源） | H3 |
| W4 | world 内「分享 session」：产出分享链接 + 别人登录后加入**同一** session（成员） | H4 |

## 依赖关系

- **红点**（H3）← world 推计数（W3）
- **查看当前session 跳转**（H2）← world 接深链（W2）
- **分享**（H4 官网侧 / W4 world 侧）共同支撑主流程第 5 步

## 对应 scenario

- 36 浏览 + 登录门控 ｜ 37 对话 + 红点 + 跳 world ｜ 38 分享 → 同一 session ｜ 39 复制配置 → 新 session

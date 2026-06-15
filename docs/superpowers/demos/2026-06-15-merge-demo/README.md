# AutoService v2 合并分支 — 演示视频(2026-06-15)

`feat/autoservice-v2-merge` 实跑录制(单租户 cinnox)。

- **takeover.gif / .mp4** — 人工客服接管(分屏:左客户 alice / 右客服 op)。
  客户提问 → 客服输入回复点「接管」(回复成草稿,**对客户不可见**)→「提交」后
  客户才看到「人工客服」回复。展示我们 P0 修对的**门控 + 权限**。
- **admin.gif / .mp4** — 租户内容管理(`/autoservice/admin`)。
  改 AI 槽位值 → 保存 → 预览渲染(完整 AI prompt)→ 发布(**Lint 通过,发布成功**)。
  我们 P1 新加的内容管理 + 崩溃安全发布。
- **final-alice.png / admin-published.png** — 关键帧静图。

登录:`/login`,客户 `entity://cinnox/user/alice`/`alice`,客服 `entity://cinnox/user/op`/`op`,
管理 `entity://cinnox/user/admin`/`admin`。

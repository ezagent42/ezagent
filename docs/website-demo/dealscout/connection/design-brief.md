# Design Brief: DealScout 双向确认

> **目标**：牵线不是单方面选中即可——双方都需要确认。发送方发起请求，接收方看到请求并决定接受/拒绝。
> **PR**：#1378

---

## 1. 流转

```
dealscout/index.html（匹配结果 → 选中 → 牵线）
  → connection/request-sent.html
    牵线请求已发送，等待对方确认
      → 对方视角：connection/inbox.html
        收到牵线请求 → 查看双方名片 → 接受 / 拒绝
          → 接受 → 双方进入 workspace
          → 拒绝 → 通知发送方 + 可重新匹配
```

## 2. 页面

| 页面 | 角色 | 内容 |
|------|------|------|
| `request-sent.html` | 发送方 | 牵线请求已发送，显示对方名片 + 等待状态 |
| `inbox.html` | 接收方 | 收到的牵线请求列表，每个请求显示对方名片 + 匹配度，可接受/拒绝 |

## 3. 不做的事

- ❌ 不实现真实的消息推送/通知后端
- ❌ 不实现 workspace session 创建

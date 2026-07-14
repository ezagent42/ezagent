# Design Brief: DealScout 异步通知

> **目标**：用户当下没匹配到合适的人，但未来平台上来了合适的信号——需要通知机制让用户回来查看。
> **PR**：#1378

---

## 1. 流转

```
dealscout/index.html（匹配结果不够好 → 保存搜索）
  → notification/saved.html
    显示已保存的搜索条件 + 匹配状态
      → 有新匹配时：标记 "new" + 通知用户
      → 点击 → 回到 dealscout/index.html 查看新结果
```

## 2. 页面

| 页面 | 内容 |
|------|------|
| `saved.html` | 已保存的搜索列表（搜索条件 + 匹配数量 + 最后更新时间）。有新结果时行高亮 + "new" badge |

## 3. 通知方式

原型 mock 三种可选：
- DealScout 页面内 badge（"3 个新匹配"）
- 浏览器通知（demo 用 `Notification API` mock）
- 邮件/飞书通知（文字占位，标注后端待建）

## 4. 不做的事

- ❌ 不实现真实通知推送
- ❌ 不实现定时爬取/匹配后端

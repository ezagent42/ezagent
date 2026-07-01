# Ezagent 官网 / 产品 UX demo · 索引

本目录按**版本**组织：`v1` = 当前可上线的官网原型，`vx` = 未来实现的探索。

## 结构

```
docs/website-demo/
├── design-ui-convergence.md   ← 设计收敛 gate（跨 5 面：Website/Hello/World/AgentConsole/Socialware，权威）
├── v1/                        ← 当前官网 demo（静态站，可上线方向）
│   ├── index.html             主站：介绍 / world.cup / 团队 三页
│   ├── worldcup.js · mock-ezagent-api.js · site-nav.js · demo-state.js
│   ├── world-demo.html · hello-demo.html · login.html · team-office.html
│   ├── tokens.css · ezagent-logo*.png
│   ├── website-review-issues.md   ← 审 zhaomato 官网的问题记录（活文档）
│   └── ui-review-gate.md          ← 各 surface 自查清单（提 PR 前自跑）
└── vx/                        ← 未来实现（尚未落地）
    ├── agent-hire-demo/       Agent Console → 招聘（候选人 profile 卡 + 场景播放）
    └── version/               官网优化 roadmap / UI-UX 审查 / dogfooding 案例
```

## 打开 v1 官网 demo

双击 **`v1/index.html`**（Chrome/Edge，需联网加载字体）；或起本地服务：

```bash
cd v1 && python3 -m http.server 8080   # 然后开 http://localhost:8080
```

- 顶部 nav：**介绍 / world.cup / 团队** 三页
- 介绍页两个产品卡有「试玩」按钮；右上角「登录」+ 深色主题切换

## 打开 vx 招聘 demo

```bash
cd vx/agent-hire-demo && python3 -m http.server 8081   # http://localhost:8081
```

> 数据 = mock + 真实 GitHub 采样；设计系统 = `ezagent-design-system`（`#E8E8EB` + cobalt `#0B5CFF` + Noto Serif SC）。
> go-live 由 @json-render 底座承接。

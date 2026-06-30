# Ezagent 官网 demo · 本地预览

一个静态站点 demo（无后端、无构建步骤）。给同事本地自己看用。

## 最简单：双击打开

直接**双击 `index.html`**，浏览器打开即可（推荐 Chrome / Edge；需联网加载字体）。

- 顶部 nav 切换 **介绍 / world.cup ⚽ / 团队** 三页
- **world.cup**：价值树（战略定位 → 痛点 → 真实 PR 成果）+「我想要」投票 + 看多/看空押注 + 双榜 + Issue→PR→Merge 三段时间线 + 场景视图
- 介绍页两个产品卡有「试玩」按钮（开占位页）；右上角有「登录」入口
- 右上角月亮图标切换**深色主题**

## 若双击打不开（个别浏览器对 file:// 有限制）

在这个文件夹里起一个本地小服务，二选一，然后浏览器开 <http://localhost:8080>：

```bash
# 有 Node：
npm start            # = npx serve . -l 8080

# 或有 Python：
python3 -m http.server 8080
```

## 文件说明

| 文件 | 是什么 |
|---|---|
| `index.html` | 主站（介绍 / world.cup / 团队 三页，单文件面板切换） |
| `worldcup.js` | world.cup 价值树 / 投票 / 押注 / 双榜 / 时间线逻辑 |
| `mock-ezagent-api.js` | mock 数据层（仿 ezagent 运行时 + 真实 GitHub PR/issue 采样） |
| `world-demo.html` / `hello-demo.html` / `login.html` | 试玩 / 登录占位页 |
| `team-office.html` | 团队办公室可视化（实验） |
| `ezagent-logo*.png` | 官方 logo（亮 / 暗） |

> 数据为 mock + 真实 GitHub 采样；设计系统 = ezagent-design（`#E8E8EB` + cobalt `#0B5CFF` + Noto Serif SC）。
> go-live 时由 @json-render 底座承接，届时直 link 真 `styles.css`。

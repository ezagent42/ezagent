# T4 接力笔记 — 手写 ruihua-faithful 官网(清爽 session 起点)

> 2026-06-30 写。这个笔记是给「清爽 session」接力用的:T4 已经踩通了 hello 渲染/发布全链路,
> 下一步是**手写 json-render body + CSS theme** 做最接近 ruihua 的官网。task branch:
> `feat/website-framework-hello-prod-0630`。

## 已完成(成果都保着)
- **site session** `session://system/hello/site`(system workspace,admin 登录)— 当前是「ruihua 风格 + 毛玻璃美化」版,在 **10042** 跑着。看: `http://localhost:10042/socialware/chat?session_uri=session://system/hello/site`
- **ruihua 手写对比站** 在 **8080**: `http://localhost:8080/index.html`(`docs/website-demo/`,`python3 -m http.server 8080`)
- 渲染/发布机制全摸清 → 见记忆 `project-hello-render-publish-mechanics`

## 清爽 session 要做的(用户拍板「尽量全 + 真数据快照」)
**我(Claude)手写**,不靠 hello LLM 生成:
1. 手写一棵 ruihua-faithful 的 json-render body spec(catalog 36 组件):
   - nav(毛玻璃)/ hero / 一个底座两个产品(world+hello 卡)
   - **Tabs 栏目切换**(介绍 / 特性 / 团队)— catalog 原生 `Tabs`
   - **团队头像墙**(`Avatar` + `Grid`)
   - **world.cup 排名表**(`Table`,**静态快照数据** — 手写时 `curl` 一次真 GitHub API 嵌入)
   - footer
2. 手写配套精致 theme(已有毛玻璃版打底,见下「现有 theme」)
3. `drive(body) + set_shell(theme)` 注入 site session + 等 publish + restart + 迭代到接近 ruihua

## 流程(已跑通,照抄)
```elixir
# mix run 脚本(PORT=10099 或停 server),drive 同/新 body + set_shell theme:
uri = Ezagent.URI.session("system", :hello, "site")
{:ok, _s, builder} = EzagentPluginHello.App.ensure_app("system", "site")  # revive 不 re-seed
# body = 手写的 spec(map: %{"type"=>"Stack","props"=>%{"className"=>"page-root"},"children"=>[...]})
EzagentPluginHello.TurnDriver.drive(uri, body, "", builder)   # 开 turn
EzagentPluginHello.TurnDriver.set_shell(uri, builder, "", theme_css)  # 同 turn
Process.sleep(13_000)  # 必须等 publish 异步跑完!否则 outbox 空
```
验证: `SELECT count(*),max(surface_version) FROM socialware_delivery_outbox WHERE session_uri='session://system/hello/site'` 应 version+1。
然后 `PORT=10042 mix phx.server` 重启 + 访问一次 socialware/chat 让它 revive。

## 关键约束
- body 只能用 `Spec.catalog/0` 36 组件;ROOT = vertical Stack className "page-root";语义 className 挂 theme
- 渲染读 **outbox** 不是 snapshot;单独 set_shell 不 publish,必须 drive+set_shell 同 turn
- 真数据:手写时 curl GitHub 嵌入(快照);要自动更新另加定期刷新 behavior(半天工程);浏览器实时拉做不到
- 精美靠 json-render body + 自由 CSS theme,**别碰 HTML shell**(shell_gen_system 是死路)

## DoD(T4)
本地证明「官网框架 + hello 页面连 backend/world」+ ruihua follow-up + 和 Allen 协调 app.ezagent.chat 生产。

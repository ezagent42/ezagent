# A5 link_anon — 真浏览器 e2e 旅程(2026-08-03,dev@10042,Playwright/Chromium)

**场景**:owner 把一块 kanban 板匿名分享;路人无账号打开链接。

| 步 | 操作 | 结果 | 证据 |
|---|---|---|---|
| S0 | 种子:建两块 kanban 板(分享板 + 未分享对照板),**各写入真实卡片**(经 `Cap.issue_for_action({:admin, …})` 现签钥匙走真实 dispatch,与 kanban 既有测试 `CapHelper.signed_action_cap!` 同一条正门),再 `AnonShare.enable(board, owner, Kanban, [:get_tree])` | `SEEDED_NODES=3`;返回专属公开会话 + 分享 URL | 种子输出 SEED_OK/SHARE_URL/PRIVATE_URL |
| S1 | **匿名**(全新无 cookie 浏览器)打开分享 URL | 页面渲染「**共享内容 · get_tree**」区块,内含**种子写进去的三张真卡**——`n1 "A5 匿名分享验收板"`(root_id)/ `n2 "访客带钥匙读到这张卡"` / `n3 "关掉分享后这张卡应消失"`,带父子关系与 CI 判据;底栏"登录后参与"=只读 | `S1-anon-sees-shared-board.png` |
| S2 | 同样匿名打开**未分享**对照板的对应 URL(该板**同样有卡片**,所以看不到不是因为它是空的) | **弹到登录墙**(会话未 provision/非公开)——每资源专属会话的结构性隔离 | `S2-isolation-private-board-login-wall.png` |
| S3 | owner 关闭分享(翻 `enabled=false`;翻行语义与 `AnonShare.disable/2` 等价,产品路径已由 `anon_share_test` ② 钉死) | — | SQL `UPDATE 1` |
| S4 | 全新匿名再开分享 URL | 页面正常加载,**共享内容区块消失**(选择器不存在,脚本断言 PASS) | `S4-after-disable-resource-gone.png` |

**第一轮截图的自我修正**:初版种子只建板、不放卡片,S1 截出来是 `{"nodes": {}}` 空树 —— 那样的图**分不清"真数据流过来了"还是"返回了个空壳"**,证明力不足。已重种真卡片重截(即上表 S0/S1)。

**过程中发现并记档的三件**(均非 A5 逻辑错):
1. **冷首访 join 内层 5s 超时**:会话冷加载后首个匿名准入 500(8.6s),第二次起 200(~3s)。冷加载本身 434ms 健康(探针 stacktrace 证),是 join 链路某嵌套 call 首触的一次性超时 —— #1576 冷 actor 同族韧性课题,待单独 triage。
2. **空字符串代理炸 esbuild watcher**:`HTTPS_PROXY=""` → `String.to_charlist(nil)` → watcher 死 → **服务器静默发旧前端包**。修法 = 启动时 `env -u`。
3. 新 worktree 未装 web assets deps → esbuild 解析失败无产物;esbuild 实际只需 react/react-dom/xterm/xterm-addon-fit 四包。

(1)(2)正是"真浏览器 e2e 才暴露"的类别 —— 单元/集成层全绿也发现不了。

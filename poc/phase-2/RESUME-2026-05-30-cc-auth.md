# RESUME(compact 后第一份读这个)—— 修本机 cc agent claude 启动 + 手测遗留

> 2026-05-30,上下文满了要 compact。这是接着干的唯一入口。机器情况见 `CLAUDE.local.md`(会自动加载)。

---

## ✅ 已解决(2026-05-30,compact 后这一轮)—— 真实根因不是 config-dir/keychain

**`/chat/cinnox` 现在能拿到真实 AI 回复,soul 也生效**(浏览器实测通过)。下面"当前任务/修复方案"里关于 **CLAUDE_CONFIG_DIR 没认证** 的诊断是**错的**(per-conv 回复 agent 根本不设 CLAUDE_CONFIG_DIR,用 ~/.claude keychain,登录一直是好的)。

**真实根因:** cc agent 的 claude 卡在**首次运行对话框**(PTY 非交互答不了)→ 不 init MCP → esr-bridge 不绑定 → `ensure_bound!` 超时 → "Could not reach the assistant"。两个对话框:
1. **folder-trust**(`Is this a project you trust?`)—— 新版 claude 新增,旧 auto-prompt(PR #22/#75)没覆盖。
2. **dev-channels** —— 旧 match `"Loading development channels"` 被 TUI 动画拆成 `"L ading"`,strip 后匹配失效。

**修复(`apps/ezagent_domain_pty/.../server.ex` 的 `default_auto_prompts/0`):** 新增 `:trust_folder_dialog`;改 `:dev_channels_dialog` 锚点为稳定菜单标签。单测 `server_auto_prompts_test.exs`(4 绿)。详见 `CLAUDE.local.md` 的"cc agent 的 AI 回复"段(含验证时发现的 3 个独立遗留问题:共享 .mcp.json 踩踏 / 15s 冷启动超时 / orchestrator 卡 onboarding)。

下面是修复前的原始诊断,保留作历史。

---

## 当前任务:打通本机 live AI 回复(用户选了「选项 2」)

**现象:** `/chat/cinnox` 发消息 → 「Could not reach the assistant」。
**已查实根因(与 soul 功能、我的 build_env/soul-file 修复**无关**,均已洗清 by T1/T2/T3):**
cc agent 用**每个 agent 独立的 `CLAUDE_CONFIG_DIR`**(`~/.ezagent/poc-phase2/cc-agents/<ws>/<agent>/.claude`,由 `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` ~line 393 创建,经 `tmpl["agent_config_dir"]` 注入)。那个 sandbox 目录**没登录** → claude 弹「Please run /login / Let's get started」引导 → PTY 非交互过不去 → 子进程**退出 256** → 页面报错。

**本机 claude 登录事实(关键):**
- `claude -p "..."`(**不**带 CLAUDE_CONFIG_DIR override)→ 正常工作(回复、exit 0)。说明 claude 默认解析能找到可用登录(**keychain**,不是文件)。
- `~/.claude/.credentials.json` **不存在**(凭据在 keychain)→ 官方 `mix ezagent.demo.seed_cc_sandbox`(靠拷 `.credentials.json`)**用不了**(该 task runbook 自己列了 "macOS Keychain has the creds (not the file)" 失败档)。
- ⚠️ **我测试时把 `~/.claude/.claude.json` 弄进了 backup**:claude 报 `Claude configuration file not found at: /Users/daiming/.claude/.claude.json`,并给了恢复命令:
  `cp "/Users/daiming/.claude/backups/.claude.json.backup.1780107812606" "/Users/daiming/.claude/.claude.json"`
  (登录/keychain 没坏,只是 `.claude.json` 这个设置/projects 文件被备份了。恢复是安全的,但**先确认再动**。)

## 已做的诊断(别重做)
- **T1:** `claude --append-system-prompt-file <89KB .esr-system-prompt.md> -p` → 回 "BIGOK", exit 0 ✅(soul 文件化没问题)
- **T2:** + `--permission-mode bypassPermissions --settings <claude-pty-settings.json>` → "T2OK", exit 0 ✅
- **T3:** `CLAUDE_CONFIG_DIR=<全新 mktemp> claude ... -p` → "Not logged in · Please run /login"(**这就是 cc agent 的处境**)
- cc agent 实际配置目录:`~/.ezagent/poc-phase2/cc-agents/<ws>/<agent>/.claude`(里面只有 `.claude.json`,无凭据)
- cc 配置目录创建逻辑在 `cc_agent.ex`:`:started` 分支「Create per-agent config_dir BEFORE PTY launch」+ 把 `agent_config_dir` 注入 tmpl;`:already_started` 分支不重建。要覆盖需看 line ~351-400 的 `config_dir_path` / `create_agent_config_dir` 逻辑。

## 修复方案(按推荐顺序,resume 时执行)
1. **先搞清楚 claude 在本机的「可用配置/登录」到底在哪**(为什么不带 override 能用、但 `~/.claude/.claude.json` 缺失):
   - 先恢复 `.claude.json`(上面的 cp 命令),再测 `CLAUDE_CONFIG_DIR=/Users/daiming/.claude claude --permission-mode bypassPermissions --append-system-prompt-file ~/poc-sandbox-phase2/cinnox/.esr-system-prompt.md --settings .../claude-pty-settings.json -p "Reply OPTA2"`。能回 → **方案 a 可行**。
2. **方案 a(推荐,最不侵入,仅本机 demo):** 让 cc agent 的 `CLAUDE_CONFIG_DIR` 指向已登录的 `~/.claude`,而不是 per-agent sandbox。
   - 落点:`apps/ezagent_plugin_customer_chat/lib/.../bootstrap.ex` 的 `ensure_cc_agent`(create_agent 的 args 里给 `claude_config_dir`),或 cc 插件一个 config 旋钮。**要 gate 成本地/demo 专用**(env 或 config),别改默认行为、别影响工作机的隔离设计。
   - 先确认:在 create_agent 里传 `claude_config_dir` 是否会跳过 per-agent dir 创建(看 cc_agent.ex line ~357 `config_dir_path`/meta 逻辑)。
3. **方案 b(备选):** 给 cc sandbox 的 settings 配 `api_key_helper`(需要用户有 ANTHROPIC_API_KEY;server 启动命令里 `env -u ANTHROPIC_API_KEY` 要相应调整)。
4. **方案 c(备选):** 想办法从 keychain 导出/生成 `.credentials.json`(`security find-generic-password` / `claude setup-token`?),再 `mix ezagent.demo.seed_cc_sandbox --name <...> --sandbox-dir <per-agent dir> --force`。

**验证方式:** 改完后 → 重启 server(命令见 CLAUDE.local.md)→ 浏览器 `/chat/cinnox` 发消息 → 应收到 AI 回复;且若先在编辑器加了 soul 标记,回复应体现该标记(这就是冒烟测试 + D2 一起做了)。

## 手动测试遗留(用户已记录在 `11-admin-edit-soul-MANUAL-TEST.md`,这里固化要点)
- **A1–A3, B1, C1, C3, D1 全部 ✅**(登录用全 URI `entity://user/system/admin` + `ezagent-dev`;裸 admin 失败是 SPEC #324,见下「登录」)。
- **B2 ❌(待修,小 UI bug):** 点 Save **没出现「已保存」提示**。原因极可能是 `ConfigLive.render` 只渲染了 `<p :if={@flash_error}>`,**没渲染 `:info` flash**(`put_flash(:info, "Soul saved...")` 无处显示;布局未含 flash group)。保存本身是好的(徽章翻 "customized" + C1/C2 的保存都成功)。修法:在 ConfigLive 渲染一个 `:info` flash 区,或加个轻量「已保存 ✓」状态。
- **A2(UI nit):** 后台 "Customer Sessions" 标题颜色太接近背景,**对比度太低**,换个颜色(DashboardLive 的 section header)。
- **A1(命名):** 用户又问「为什么路由有 operator」。已答:`/operator/:tenant` 是操作员控制台(贴切);配置编辑器已挪到 `/plugins/customer-chat/:tenant/config`。若想把 "operator" 这个词换掉(/console 等)是纯命名偏好,可单独议。
- **C2(产品设计问题,需回答+可能改):** 用户问 Revert 的语义——他要的是「**应用 soul 后能退回上一个已应用版本**」(admin 改完去客服对话测,测不好就回退),不是「只在编辑框里回退文本」。
  - **事实:** 我们的 Revert **已经**是「回退已应用版本」——`SoulStore.revert_previous` 做的是 `File.cp!(.prev → edited)`,即把**生效的** edited 文件覆盖回上一版 → 新会话就用回退后的 soul。所以**和用户意图一致**。
  - **唯一限制:** 只有**单级**历史(`.prev` 只存上一版)。多版本历史是当初 deferred 的。
  - **作为 PM 的建议(待和用户确认):** 单级 Revert + Reset-to-default 已覆盖「上次改坏 → 退一步 / 退到原始」的核心环;多版本历史等真实使用证明需要再退 >1 版时再做(增量,符合战略红线)。要不要现在就把 Revert 文案/交互讲清楚(让 admin 知道它退的是"已应用版本"),也是个小改进。

## 登录(本机,已查实)
- 裸 `admin`(`/login` 无 `?workspace=`)→ 失败「Invalid URI or credentials」,因 **PR #324**「裸 handle 必须带 workspace,无静默默认」。报错把「缺 workspace」和「密码错」混了(未记录的 UX 回归;登录页第 56 行提示已过时)。
- **能登:** 全 URI `entity://user/system/admin` + `ezagent-dev`;或 `/login?workspace=system` 后用裸 `admin`。
- 相关已存在 issue:**#392**(build_env 空值 env → cc spawn 失败)= 我们这次 env 修复(`200c3317`)已解决,可去 link/close;**#395**(fresh boot admin Kind 不可达)邻近。登录 UX bug 本身**无 issue**。

## 分支状态
`poc/phase-2-customer-service`,已 push 到 origin。本次未提交的改动:`.gitignore`(+CLAUDE.local.md 忽略)、手测文档、本 RESUME 文档、CLAUDE.local.md(gitignore 不提交)。代码修复(env/soul-file/inline-confirm 等)都已提交+push。

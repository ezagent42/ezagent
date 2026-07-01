# Handoff → zhaomato · Hello 官网对话框（门户助手）+ 留资页面

> **From:** ruihua（designer） · **Date:** 2026-07-01
> **Ladder:** lead 2026-07-01「产品形态收口」问②——官网对话框支持哪些交流主题 + 如何配置
> **权威文档:** `docs/together/2026-07-01/design-ui-convergence.md`

## 先读文档这几段（按序）

1. **§2 什么是共通的** —— 品牌唯一权威源 = `ezagent-design-system`（rev `ebce041`）。**官网 `docs/website-demo/tokens.css` 请对齐上游、不另立标准。**
2. **§1① Website / §1② Hello** —— 官网 = hello 生成的页面；hello builder 三模式；session `session://system/hello/site` + agent `hello_web`。
3. **§5.2（重点，全读）** —— 官网对话框定位、主题清单、留资页面、5 个技术待办。

## 你要做什么

### 1. 过一遍主题清单（§5.2），确认增删
- ✅ 支持（导航式回答官网内容：产品/两个产品/进度 world.cup/团队/导航/关于自己）
- ⚠️ 官网没有的：有接触意图 → **开留资页**（定价/私有化/销售/合作/投资/招聘）；纯站外事实 → 据实答不了
- 🚫 边缘/高危（提示注入/当免费GPT/数据窃取/有害/冒充/刷量/垃圾/法务）

### 2. 回答 §5.2 末 5 个技术待办（你更懂后端）
1. **grounding 三源**怎么喂 `hello_web`：① 官网页面文案 ② world.cup 真 GitHub 数据（`scripts/refresh_hello_site.exs` 已拉）③ 团队 `docs/together/team.md`。范围外一律 fallback。
2. **导航式回答**（⚠️关键）：对话框**不是纯文字**，要[替访客切页面/滚动 + 短文字]。agent 怎么触发页面动作？需一套动作词表 `scroll_to / switch_tab / highlight / open_url / open_lead_form` + 前端执行——技术形式你定。
3. **留资页面**怎么落：必填=姓名+联系方式(邮箱/手机/微信任一)+隐私同意；选填=公司/职位/规模/场景；intent 由触发问题预填并按 intent 路由收件人（销售/founder/HR）；自动带来源问题。
4. **范围外 fallback**（如定价→开留资）在 system prompt / routing 怎么落。
5. 对话框**只读官网、不生成/改/发布内容、无后台变更、无跨 session 读**——怎么在 prompt/routing 保证。

### 3. 官网侧品牌对齐
- `tokens.css` 对齐上游 design-system；动作色唯一钴蓝 `#0B5CFF`、禁渐变、白卡浅灰底、双语 Sentence-case、无 emoji。

## 请回给我什么
- 在 `design-ui-convergence.md` §5.2 回填技术结论（或写 return 指给我）。
- 留资页面**是不是也用 hello 生成**（还是独立静态页/表单组件）？这决定它归你还是我出设计——请明确。

## 关联
- 你昨天的交付 #1107（官网框架 + hello 渲染）+ `docs/together/2026-06-30/t4-handwrite-ruihua-NOTES.md`
- hello builder 截图 `docs/together/2026-06-30/evidence/hello-ui/`

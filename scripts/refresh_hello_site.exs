# ============================================================================
# refresh_hello_site — repeatable refresh of the hello "site" page.
#
# Fetches LIVE GitHub data (ezagent42/ezagent contributors + merged PRs + repo
# meta) and re-drives a ruihua-faithful catalog/json-render body + CSS theme into
# session://system/hello/web (drive(body)+set_shell(theme) same turn + wait for
# the async publish). Falls back to a 2026-06-30 snapshot if GitHub is unreachable.
#
# RUN (manual or cron):
#   cd /home/ning/ezagent
#   export PATH="$HOME/.local/bin:$HOME/.local/linux-node/bin:$PATH"
#   set -a; . ./.env 2>/dev/null; set +a
#   export POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=55432 \
#          POSTGRES_USER=ezagent_pg_compat POSTGRES_PASSWORD=ezagent_pg_compat \
#          POSTGRES_DB=ezagent_pg_compat_dev
#   PORT=10099 mix run scripts/refresh_hello_site.exs
#
# After it bumps the outbox version, viewers see the new data on the next page
# load. NOTE: this runs as a separate BEAM node from the live server (PORT=10042),
# so the running server's clients won't hot-update — a hard refresh re-fetches the
# new outbox version. For guaranteed propagation of a brand-new surface the server
# can be restarted, but a plain data refresh does not require it.
# ============================================================================

defmodule SiteData do
  @repo "ezagent42/ezagent"
  @proxy "http://127.0.0.1:7890"

  # static roster (docs/together/team.md) — gh -> {cn, role_badge, badge_variant, track, tz}
  def roster do
    %{
      "allenwoods"          => {"林懿伦", "lead · 队长",     "default",   "dev-together lead · 架构地基 / 部署", "GMT+9"},
      "jjkysy"              => {"姚升悦", "dev · 开发",      "secondary", "架构 / 原则把关 · kanban 插件原作",     "GMT+8"},
      "gagameow"            => {"黄佳佳", "dev · 开发",      "secondary", "agent-config 后端契约",               "GMT+8"},
      "zyli-developer"      => {"李震宇", "dev · 开发",      "secondary", "人肉 full-flow validation · E2E",      "GMT+8"},
      "zhaomaota97"         => {"张宁",   "dev · 开发",      "secondary", "官网（@json-render 底座）",            "GMT+8"},
      "FatNine"             => {"戴明",   "dev · 开发",      "secondary", "#84 Agent Console CRUD",              "GMT+8"},
      "ruihuachen-designer" => {"陈瑞华", "designer · 设计", "default",   "产品 / 设计版式 · 可外发文档",         "GMT+8"},
      "claude"              => {"Claude", "agent · AI",     "outline",   "off-plan support · 编排 / 修复",       "—"},
      "codex"              => {"Codex",  "agent · AI",     "outline",   "off-plan support · 有界可验子任务",     "—"}
    }
  end

  def order, do: ~w(allenwoods jjkysy gagameow zyli-developer zhaomaota97 FatNine ruihuachen-designer claude codex)

  defp curl(path) do
    url = "https://api.github.com/repos/#{@repo}#{path}"
    case System.cmd("curl", ["-s", "--max-time", "15", "-x", @proxy, "-H", "Accept: application/vnd.github+json", url], stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, data} -> {:ok, data}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @snapshot_contrib [
    {"allenwoods", 951}, {"gagameow", 14}, {"zyli-developer", 10}, {"FatNine", 5},
    {"zhaomaota97", 5}, {"jjkysy", 1}, {"ruihuachen-designer", 1}
  ]
  @snapshot_prs [
    {"1102", "close 0629 and plan 0630", "allenwoods", "docs"},
    {"1099", "render_card tool + fix main compile", "zhaomaota97", "feat"},
    {"1100", "AI 开发治理机制 rule-gate 设计", "FatNine", "docs"},
    {"1096", "Fix AutoService cc orchestrator materialization", "gagameow", "fix"},
    {"1083", "migrate handoff surfaces to shadcn brand system", "zyli-developer", "feat"},
    {"1090", "官网 demo — 多页站点 + mock ezagent API", "ruihuachen-designer", "feat"},
    {"1098", "config_dir.ex syntax — validate_project_cwd", "allenwoods", "fix"},
    {"1097", "validate project_cwd within allowed roots", "allenwoods", "fix"}
  ]

  defp kind(t) do
    cond do
      String.starts_with?(t, "feat") -> "feat"
      String.starts_with?(t, "fix") -> "fix"
      String.starts_with?(t, "docs") -> "docs"
      String.starts_with?(t, "chore") -> "chore"
      String.starts_with?(t, "refactor") -> "refactor"
      true -> "other"
    end
  end

  defp clean_title(t) do
    t
    |> String.replace(~r/^\w+(\([^)]*\))?:\s*/, "")
    |> String.replace(~r/\s*\(#\d+\).*$/, "")
    |> String.slice(0, 52)
  end

  def fetch do
    {contrib, c_src} =
      case curl("/contributors?per_page=12") do
        {:ok, list} when is_list(list) and length(list) > 0 ->
          {Enum.map(list, fn c -> {c["login"], c["contributions"]} end), :live}

        _ ->
          {@snapshot_contrib, :snapshot}
      end

    {prs, p_src} =
      case curl("/pulls?state=closed&per_page=30&sort=updated&direction=desc") do
        {:ok, list} when is_list(list) ->
          merged =
            list
            |> Enum.filter(& &1["merged_at"])
            |> Enum.take(8)
            |> Enum.map(fn p ->
              {to_string(p["number"]), clean_title(p["title"]), p["user"]["login"], kind(p["title"])}
            end)

          if merged == [], do: {@snapshot_prs, :snapshot}, else: {merged, :live}

        _ ->
          {@snapshot_prs, :snapshot}
      end

    {meta, m_src} =
      case curl("") do
        # only trust the repo payload when it carries real fields; a 403 rate-limit
        # / error body is also a map and would otherwise nil out issues/lang.
        {:ok, %{"stargazers_count" => stars} = d} when is_integer(stars) ->
          {%{stars: stars, forks: d["forks_count"], issues: d["open_issues_count"], lang: d["language"]}, :live}

        _ ->
          {%{stars: 0, forks: 1, issues: 46, lang: "Elixir"}, :snapshot}
      end

    %{contrib: contrib, prs: prs, meta: meta, sources: %{contrib: c_src, prs: p_src, meta: m_src}}
  end
end

defmodule Build do
  def n(type, props, children \\ []), do: %{"type" => type, "props" => props, "children" => children}
  def stack(cls, opts, children), do: n("Stack", Map.merge(%{"direction" => "vertical", "gap" => "none", "className" => cls}, opts), children)
  def text(t, v), do: n("Text", %{"text" => t, "variant" => v})
  def heading(t, lvl), do: n("Heading", %{"text" => t, "level" => lvl})
  def badge(t, v), do: n("Badge", %{"text" => t, "variant" => v})
  def button(l, v), do: n("Button", %{"label" => l, "variant" => v})
  def img(src, alt), do: n("Image", %{"src" => src, "alt" => alt, "width" => 24, "height" => 24})

  def subcard(eyebrow, h, body) do
    stack("subcard", %{"gap" => "none"}, [text(eyebrow, "caption"), heading(h, "h4"), text(body, "muted")])
  end

  def product(extra_cls, glyph_src, eyebrow, h, lead, subs, btn, tags) do
    n("Card", %{"className" => "product #{extra_cls}"}, [
      stack("glyph", %{"align" => "center", "justify" => "center"}, [img(glyph_src, eyebrow)]),
      text(eyebrow, "code"),
      heading(h, "h3"),
      text(lead, "body"),
      stack("subcards", %{"gap" => "sm"}, Enum.map(subs, fn {e, hh, b} -> subcard(e, hh, b) end)),
      stack("product-foot", %{"direction" => "horizontal", "gap" => "sm", "align" => "center"},
        [button(btn, "default") | Enum.map(tags, &badge(&1, "outline"))])
    ])
  end

  def member({gh, contrib_n}) do
    {cn, role, variant, track, tz} = Map.get(SiteData.roster(), gh, {gh, "agent", "outline", "", "—"})

    avatar =
      if gh in ["claude", "codex"] do
        n("Avatar", %{"src" => nil, "name" => cn, "size" => "lg"})
      else
        n("Avatar", %{"src" => "https://github.com/#{gh}.png?size=96", "name" => cn, "size" => "lg"})
      end

    sub = if contrib_n, do: "@#{gh} · #{contrib_n} commits", else: "@#{gh} · #{tz}"

    n("Card", %{"className" => "member#{if variant == "outline", do: " member-agent", else: ""}"}, [
      stack("member-top", %{"direction" => "horizontal", "gap" => "sm", "align" => "center"}, [
        avatar,
        stack("member-id", %{"gap" => "none"}, [heading(cn, "h4"), text(sub, "caption")])
      ]),
      badge(role, variant),
      text(track, "muted")
    ])
  end
end

# ── fetch live data ───────────────────────────────────────────────────────────
data = SiteData.fetch()
IO.puts("data sources: #{inspect(data.sources)}")
contrib_n = Map.new(data.contrib)

pr_rows = Enum.map(data.prs, fn {num, title, author, k} -> ["##{num}", title, author, k] end)

contrib_rows =
  data.contrib
  |> Enum.with_index(1)
  |> Enum.map(fn {{gh, cnt}, i} ->
    {cn, _r, _v, track, _tz} = Map.get(SiteData.roster(), gh, {gh, "", "", "", ""})
    [to_string(i), "#{gh} · #{cn}", to_string(cnt), track]
  end)

team_members = Enum.map(SiteData.order(), fn gh -> Build.member({gh, contrib_n[gh]}) end)
latest_pr = data.prs |> List.first() |> elem(0)
src_label = if data.sources.contrib == :live, do: "实时拉取", else: "快照"

# ── BODY (catalog-only, full-width band layout) ───────────────────────────────
body =
  Build.stack("page-root", %{"gap" => "none"}, [
    # nav (centered pill)
    Build.stack("nav", %{"direction" => "horizontal", "align" => "center", "justify" => "between"}, [
      Build.stack("brand", %{"direction" => "horizontal", "align" => "center", "gap" => "sm"}, [
        Build.n("Image", %{"src" => "/images/ezagent-logo.png", "alt" => "Ezagent", "width" => 20, "height" => 24}),
        Build.text("EZAGENT", "body")
      ]),
      Build.stack("navlinks", %{"direction" => "horizontal", "align" => "center", "gap" => "sm"}, [
        Build.n("Link", %{"label" => "↗ GitHub", "href" => "https://github.com/ezagent42"}),
        Build.button("登录 · Login", "secondary")
      ])
    ]),

    # hero (full-bleed white band)
    Build.stack("hero", %{"gap" => "none"}, [
      Build.badge("Organization IDE · 2026", "secondary"),
      Build.heading("组织的 IDE。", "h1"),
      Build.heading("Organization IDE.", "h2"),
      Build.text("Ezagent 让你用一套柔软而清晰的界面，构建、运行并交付组织的 AI agent。把整个组织的复杂度变得在手、可搭建 — build, run, and ship agents. 纯色为轴，留白为形。", "lead"),
      Build.stack("cta", %{"direction" => "horizontal", "gap" => "sm"}, [
        # W3: 开始使用 → open the GitHub repo in a new tab (renderer honors onClickUrl)
        Build.n("Button", %{"label" => "开始使用 · Get started →", "variant" => "default", "onClickUrl" => "https://github.com/ezagent42/ezagent"}),
        # W4: 看看进度 → dispatch jr-tab-switch to the world.cup/Progress tab + scroll
        Build.n("Button", %{"label" => "看看进度 · See progress", "variant" => "secondary", "onClickUrl" => "#worldcup"})
      ])
    ]),

    # products (ground band)
    Build.stack("section products-section", %{"gap" => "none"}, [
      Build.text("OPEN SOURCE · 开源项目", "caption"),
      Build.heading("一个底座，两个产品", "h2"),
      Build.text("同一套 ezagent 地基之上 — world 让消息可靠流转，hello 让界面即问即生。", "muted"),
      Build.n("Grid", %{"columns" => 2, "gap" => "lg", "className" => "product-grid"}, [
        Build.product("product-world", "/images/ruihua-world.svg", "world · 连接层 · routing",
          "让消息在工具、渠道、AI 之间顺畅流转",
          "任意渠道接进来、每条消息都接得住、想换模型或后端配置一下就行——对客流水线不丢一条。",
          [{"连接 · CONNECT", "接得住任意渠道", "飞书、webhook、自定义系统，连上就能用，新增渠道不用重做一遍。"},
           {"稳定 · RELIABLE", "消息不丢、有兜底", "先落库再处理，重启自恢复；没人接的消息也有明确去处，不会悄悄消失。"},
           {"灵活 · FLEXIBLE", "换 AI / 后端不重写", "模型、服务都可替换，配置代替改代码——换个大脑不动地基。"}],
          "试玩 · Try world →", ["message-router", "no-drop"]),
        Build.product("product-hello", "/images/ruihua-hello.svg", "hello · 生成层 · generation",
          "用一句话，生成你要的界面",
          "说清你想要什么，界面当场长出来，还会为每个客户实时重组——不写一行前端。",
          [{"生成 · GENERATE", "一句话生成可用界面", "说清想要什么，界面当场长出来，不用排开发的期。"},
           {"定制 · PER-CUSTOMER", "为每个客户实时重组", "同一会话，不同的人打开，看到的是为他重新组合的样子。"},
           {"微调 · TWEAK", "细节随手可调", "生成完想改哪改哪，描述一句就变，不必从头再来。"}],
          "试玩 · Try hello →", ["json-render", "say-it-grows"])
      ])
    ]),

    # foundation (dark band)
    Build.stack("foundation", %{"direction" => "horizontal", "gap" => "sm", "align" => "center"}, [
      Build.badge("ezagent", "default"),
      Build.text("一个底座，两个产品 · One substrate, two products", "body"),
      Build.text("core · Kind / Behavior / dispatch / CapBAC / 可靠性原语", "code")
    ]),

    # section tabs — REAL content switching (ruihua W2). The two sections are the
    # Tabs node's 2 CHILDREN (child[i] ↔ tabs[i]): TabsSwitch
    # (catalog_jsonrender.mjs) renders ONLY the active child = true switch, not a
    # decorative bar with both sections always visible. Order MUST match:
    #   tab[0] worldcup → child[0] worldcup(研发进度)section
    #   tab[1] team     → child[1] team(核心团队)section
    # defaultValue "worldcup" shows 研发进度 first. W4 "看看进度" CTA
    # (onClickUrl "#worldcup") dispatches jr-tab-switch → worldcup is a valid tab
    # value, so it switches to the worldcup panel + scrolls the tab bar into view.
    Build.stack("tabbar-band", %{"gap" => "none"}, [
      Build.n("Tabs", %{"defaultValue" => "worldcup", "tabs" => [
        %{"label" => "研发进度 · Progress", "value" => "worldcup"},
        %{"label" => "核心团队 · Team", "value" => "team"}
      ]}, [
        # child[0] — worldcup (研发进度) panel (tinted band)
        Build.stack("section worldcup", %{"gap" => "none"}, [
          Build.stack("worldcup-head", %{"direction" => "horizontal", "align" => "center", "gap" => "sm"}, [
            Build.n("Image", %{"src" => "/images/ruihua-ball.svg", "alt" => "world.cup", "width" => 30, "height" => 30}),
            Build.text("PROGRESS · world.cup", "caption")
          ]),
          Build.heading("研发进度与公开路线图", "h2"),
          Build.text("每一项进展都来自真实研发，可追溯至对应 PR、commit 与里程碑 — 不夸大、不造势。数据来自 github.com/ezagent42/ezagent（#{src_label}）。", "muted"),
          Build.n("Grid", %{"columns" => 4, "gap" => "md", "className" => "stat-row"}, [
            Build.n("Card", %{"className" => "stat"}, [Build.heading("##{latest_pr}", "h3"), Build.text("最新合并 PR", "caption")]),
            Build.n("Card", %{"className" => "stat"}, [Build.heading(to_string(length(data.contrib)), "h3"), Build.text("活跃贡献者", "caption")]),
            Build.n("Card", %{"className" => "stat"}, [Build.heading(to_string(data.meta.issues), "h3"), Build.text("开放 issue", "caption")]),
            Build.n("Card", %{"className" => "stat"}, [Build.heading(to_string(data.meta.lang), "h3"), Build.text("主语言 · OTP", "caption")])
          ]),
          Build.heading("近期已合并 · Recently merged", "h4"),
          Build.n("Table", %{"caption" => "实时 / 快照 · github.com/ezagent42/ezagent · merged PRs",
            "columns" => ["PR", "进展", "作者", "类型"], "rows" => pr_rows}),
          Build.heading("贡献榜 · Contributor leaderboard", "h4"),
          Build.n("Table", %{"caption" => "contributions API · 按提交数排序",
            "columns" => ["#", "贡献者", "提交数", "方向"], "rows" => contrib_rows})
        ]),

        # child[1] — team (核心团队) panel (ground band)
        Build.stack("section team", %{"gap" => "none"}, [
          Build.text("CONTRIBUTORS · 团队", "caption"),
          Build.heading("核心团队", "h2"),
          Build.text("用 AI agent 协作开发自身产品的核心团队 · 数据源 docs/together/team.md。", "muted"),
          Build.n("Grid", %{"columns" => 3, "gap" => "lg", "className" => "team-wall"}, team_members)
        ])
      ])
    ]),

    # footer
    Build.stack("footer", %{"gap" => "none", "align" => "center"}, [
      Build.n("Separator", %{"orientation" => "horizontal"}),
      Build.text("组织的 IDE · Organization IDE — Ezagent", "body"),
      Build.text("hand-written json-render · catalog 组件 · ruihua SVG + 真实 GitHub 数据", "code")
    ])
  ])

case EzagentPluginHello.Spec.validate(body) do
  {:ok, _} -> IO.puts("✓ body validates against catalog")
  {:error, reason} ->
    IO.puts("✗ INVALID: #{inspect(reason)}")
    System.halt(1)
end

# ── THEME (free CSS — full-bleed bands + ruihua ezagent-design tokens) ────────
theme_css = ~S"""
.page-root{
  --ground:#E8E8EB;--ground-2:#EFEFF1;--ground-hover:#E4E4E8;--card:#FFFFFF;
  --ink:#17171B;--ink-2:#56565E;--ink-3:#8A8A92;--ink-4:#B6B6BC;--line:#E2E2E6;
  --red:#D81830;--blueink:#0048A8;--yellow:#FFD400;--jade:#0FA06E;
  --blue:#0B5CFF;--blue-deep:#0040C4;--blue-wash:#E7EEFF;--orange:#FF8A1E;
  --jade-wash:#DCF1E8;--accent:#0B5CFF;--accent-hover:#1466FF;--on-accent:#FFFFFF;
  --r-md:16px;--r-lg:22px;--r-pill:999px;--stage:#14131C;
  --font-ui:'Inter',system-ui,-apple-system,sans-serif;
  --font-cn:'Noto Serif SC','Songti SC',serif;
  --font-cn-ui:'Noto Sans SC','PingFang SC',sans-serif;
  --font-mono:'Space Mono',ui-monospace,Menlo,monospace;
  --shadow-sm:0 1px 2px rgba(15,15,15,.04),0 8px 24px -12px rgba(15,15,15,.14);
  --shadow-card:0 60px 80px rgba(15,15,15,.07),0 25px 33px rgba(15,15,15,.05),0 7.5px 10px rgba(15,15,15,.04),0 1.7px 2.2px rgba(15,15,15,.022);
  --shadow-accent:0 10px 24px -8px rgba(11,92,255,.5);
  --glass:rgba(255,255,255,.62);
  --maxw:1340px;
  --pad-x:max(28px,calc((100% - var(--maxw)) / 2));
  /* W5: reserve room for the fixed socialware composer bar (~90px) so the last
     row of content is never hidden behind it. */
  width:100%;max-width:none;margin:0;padding:0 0 108px;
  background:var(--ground);color:var(--ink);
  font-family:var(--font-cn-ui),var(--font-ui);font-weight:450;
  -webkit-font-smoothing:antialiased;line-height:1.55;
}
.page-root *{box-sizing:border-box}

/* ── full-bleed bands: background spans viewport, content centered via padding ── */
.page-root > .hero,
.page-root > .products-section,
.page-root > .foundation,
.page-root > .tabbar-band,
.page-root > .footer{padding-inline:var(--pad-x)}
/* worldcup/team are NO LONGER page-root children — they live inside the Tabs as
   .jr-tabs-content panels; their gutter is re-applied below via .jr-tabs-content. */

/* nav — centered floating glass pill */
.page-root .nav{
  position:sticky;top:14px;z-index:50;width:calc(100% - 48px);max-width:var(--maxw);
  margin:16px auto 0;padding:9px 12px 9px 16px;border-radius:var(--r-pill);
  background:var(--glass);backdrop-filter:blur(14px) saturate(1.4);-webkit-backdrop-filter:blur(14px) saturate(1.4);
  box-shadow:var(--shadow-sm),inset 0 0 0 1px rgba(255,255,255,.65);
}
.page-root .brand{gap:10px}
.page-root .brand img{height:24px;width:auto;display:block}
.page-root .brand p{font-family:var(--font-ui);font-weight:800;letter-spacing:-.01em;font-size:16px;color:var(--ink);margin:0}
.page-root .navlinks a{font-family:var(--font-mono);font-size:12px;color:var(--ink-2);background:var(--ground-2);padding:9px 15px;border-radius:var(--r-pill);text-decoration:none}
.page-root .navlinks a:hover{background:var(--ink);color:var(--card)}
.page-root .navlinks [data-slot=button]{background:var(--blue-wash);color:var(--blue-deep);border:0;border-radius:var(--r-pill);font-family:var(--font-mono);font-weight:700;font-size:12px;height:auto;padding:9px 16px}
.page-root .navlinks [data-slot=button]:hover{background:var(--accent);color:#fff}

/* hero — full-bleed white band */
.page-root .hero{
  margin-top:18px;padding-top:74px;padding-bottom:60px;background:var(--card);
  box-shadow:inset 0 -1px 0 var(--line);display:flex;flex-direction:column;
}
.page-root .hero [data-slot=badge]{align-self:flex-start;background:var(--blue-wash);color:var(--blue-deep);border:0;border-radius:var(--r-pill);font-family:var(--font-mono);font-weight:700;font-size:11px;letter-spacing:.04em;padding:5px 12px;margin-bottom:18px}
.page-root .hero h1{font-family:var(--font-cn);font-weight:600;font-size:clamp(46px,6.6vw,76px);line-height:1.08;letter-spacing:.01em;color:var(--ink);margin:0}
.page-root .hero h2{font-family:var(--font-ui);font-weight:800;font-size:clamp(24px,3vw,34px);letter-spacing:-.02em;color:var(--ink-2);margin:10px 0 0}
.page-root .hero p{font-size:19px;line-height:1.6;color:var(--ink-2);max-width:62ch;margin:22px 0 0}
.page-root .cta{margin-top:36px}
.page-root .cta [data-slot=button]{font-family:var(--font-ui);font-weight:600;font-size:15px;height:auto;padding:14px 26px;border-radius:var(--r-pill)}
.page-root .cta [data-slot=button]:first-child{background:var(--accent);color:var(--on-accent);box-shadow:var(--shadow-accent);border:0}
.page-root .cta [data-slot=button]:first-child:hover{background:var(--accent-hover)}
.page-root .cta [data-slot=button]:last-child{background:var(--ground-2);color:var(--ink);border:0}

/* section heads (shared) */
.page-root .section{padding-top:60px;padding-bottom:8px}
.page-root .section > p:first-of-type{font-family:var(--font-mono);font-size:11px;letter-spacing:.14em;color:var(--ink-3);margin:0 0 8px}
.page-root .section > h2{font-family:var(--font-cn);font-weight:600;font-size:clamp(28px,3.4vw,36px);line-height:1.2;color:var(--ink);margin:0}
.page-root .section > p:nth-of-type(2),.page-root .worldcup > p{color:var(--ink-2);font-size:16px;margin:10px 0 0;max-width:70ch}

/* products */
.page-root .product-grid{margin-top:28px}
.page-root .product{padding:34px 36px;border-radius:var(--r-lg);background:var(--card);box-shadow:var(--shadow-card);border:0;display:flex;flex-direction:column;gap:12px;position:relative}
.page-root .glyph{position:absolute;top:28px;right:30px;width:46px;height:46px;border-radius:var(--r-md);flex:none}
.page-root .glyph img{width:24px;height:24px;display:block}
.page-root .product-world .glyph{background:var(--blue)}
.page-root .product-hello .glyph{background:var(--orange)}
.page-root .product > code{font-family:var(--font-mono);font-size:12px;letter-spacing:.06em;background:transparent;padding:0}
.page-root .product-world > code{color:var(--blue)}
.page-root .product-hello > code{color:var(--orange)}
.page-root .product > h3{font-family:var(--font-cn);font-weight:600;font-size:23px;color:var(--ink);margin:0;max-width:80%}
.page-root .product > p{color:var(--ink-2);line-height:1.6;font-size:15px;margin:0}
.page-root .subcards{margin-top:6px}
.page-root .subcard{background:var(--ground-2);border-radius:var(--r-md);padding:13px 16px}
.page-root .subcard p:first-child{font-family:var(--font-mono);font-size:11px;letter-spacing:.05em;color:var(--accent);margin:0}
.page-root .subcard h4{font-family:var(--font-cn-ui);font-weight:600;font-size:15px;color:var(--ink);margin:4px 0}
.page-root .subcard p:last-child{font-size:13px;color:var(--ink-2);line-height:1.5;margin:0}
.page-root .product-foot{margin-top:8px}
.page-root .product-foot [data-slot=button]{background:var(--accent);color:#fff;border:0;border-radius:var(--r-pill);font-weight:600;font-size:14px;height:auto;padding:10px 18px;box-shadow:var(--shadow-accent)}
.page-root .product-foot [data-slot=badge]{font-family:var(--font-mono);font-size:11px;color:var(--ink-2);background:transparent;border:1px solid var(--line);border-radius:var(--r-pill);padding:3px 10px}

/* foundation — dark band */
.page-root .foundation{margin-top:46px;padding-top:24px;padding-bottom:24px;background:var(--stage);color:#F4F2EC;align-items:center}
.page-root .foundation [data-slot=badge]{background:var(--jade);color:#04130d;border:0;border-radius:var(--r-pill);font-family:var(--font-mono);font-weight:700}
.page-root .foundation p:nth-of-type(1){font-family:var(--font-cn);font-weight:500;font-size:16px;color:#F4F2EC;margin:0}
.page-root .foundation code{font-family:var(--font-mono);font-size:12px;color:#85837B;background:transparent;margin-left:auto;padding:0}

/* tab bar band — the pills sit at the page gutter (tabbar-band padding-inline) */
.page-root .tabbar-band{padding-top:46px;padding-bottom:0;background:var(--ground)}
.page-root [data-slot=tabs-list]{background:var(--ground-2);border-radius:var(--r-pill);padding:5px;gap:4px;height:auto;display:inline-flex}
.page-root [data-slot=tabs-trigger]{font-family:var(--font-ui);font-weight:600;font-size:13px;color:var(--ink-2);border-radius:var(--r-pill);padding:9px 18px;border:0}
.page-root [data-slot=tabs-trigger][data-state=active]{background:var(--accent);color:#fff;box-shadow:var(--shadow-accent)}

/* tab content panels (REAL switch). worldcup/team are the Tabs' 2 children;
   TabsSwitch wraps each in .jr-tabs-content (hidden unless active). The wrapper
   inherits tabbar-band's padding-inline, so: (a) enforce show/hide on [hidden];
   (b) bleed the panel back to full viewport width (negative margin cancels the
   tabbar gutter) so worldcup's tinted band stays full-bleed; (c) re-apply the
   page gutter to the inner content so it never glues to the left edge (this is
   the alignment fix the coordinator called out). */
.page-root .jr-tabs-content[hidden]{display:none}
.page-root .jr-tabs-content{margin-inline:calc(-1 * var(--pad-x))}
.page-root .jr-tabs-content > *{padding-inline:var(--pad-x, max(28px, calc((100% - 1340px) / 2)))}

/* world.cup — tinted band */
.page-root .worldcup{background:#F1F0F4;padding-top:40px;padding-bottom:56px}
.page-root .worldcup-head{margin-bottom:8px}
.page-root .worldcup-head img{width:30px;height:30px;display:block}
.page-root .worldcup-head p{font-family:var(--font-mono);font-size:11px;letter-spacing:.14em;color:var(--ink-3);margin:0}
.page-root .worldcup > h2{font-family:var(--font-cn);font-weight:600;font-size:clamp(28px,3.4vw,36px);color:var(--ink);margin:0}
.page-root .stat-row{margin-top:24px}
.page-root .stat{padding:18px 20px;border-radius:var(--r-md);background:var(--card);box-shadow:var(--shadow-sm);border:0}
.page-root .stat h3{font-family:var(--font-ui);font-weight:800;font-size:26px;letter-spacing:-.01em;color:var(--ink);margin:0}
.page-root .stat p{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);margin:4px 0 0}
.page-root .worldcup h4{font-family:var(--font-cn);font-weight:600;font-size:18px;color:var(--ink);margin:32px 0 12px}
.page-root .worldcup .rounded-md,.page-root .worldcup [data-slot=table-container]{border-radius:var(--r-lg)!important;border:0!important;background:var(--card);box-shadow:var(--shadow-card);overflow:hidden}
.page-root .worldcup table{font-size:14px;width:100%}
.page-root .worldcup thead{background:var(--ground-2)}
.page-root .worldcup th{font-family:var(--font-mono);font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:var(--ink-3);text-align:left;padding:12px 16px}
.page-root .worldcup td{padding:12px 16px;color:var(--ink);border-top:1px solid var(--line)}
.page-root .worldcup td:first-child{font-family:var(--font-mono);font-weight:700;color:var(--accent)}
.page-root .worldcup caption{caption-side:bottom;font-family:var(--font-mono);font-size:11px;color:var(--ink-3);padding:10px 16px;text-align:left}

/* team — ground band */
.page-root .team{padding-bottom:60px}
.page-root .team-wall{margin-top:28px}
.page-root .member{padding:22px 24px;border-radius:var(--r-lg);background:var(--card);box-shadow:var(--shadow-card);border:0;display:flex;flex-direction:column;gap:10px}
.page-root .member-top{margin-bottom:2px}
.page-root .member [data-slot=avatar]{box-shadow:var(--shadow-sm)}
.page-root .member [data-slot=avatar-fallback]{background:var(--accent);color:#fff;font-family:var(--font-ui);font-weight:700}
.page-root .member-id h4{font-family:var(--font-cn);font-weight:600;font-size:17px;color:var(--ink);margin:0}
.page-root .member-id p{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);margin:2px 0 0}
.page-root .member [data-slot=badge]{align-self:flex-start;border-radius:var(--r-pill);font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:.03em;padding:4px 11px}
.page-root .member > p:last-child{font-size:13.5px;color:var(--ink-2);line-height:1.5;margin:0}
.page-root .member-agent{background:var(--ground-2);box-shadow:var(--shadow-sm)}

/* footer */
.page-root .footer{padding-top:36px;padding-bottom:40px;color:var(--ink-3);text-align:center;display:flex;flex-direction:column;align-items:center}
.page-root .footer [data-slot=separator]{background:var(--line);margin-bottom:18px;width:100%;max-width:200px}
.page-root .footer p:first-of-type{font-size:13px;color:var(--ink-2)}
.page-root .footer code{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);background:transparent}

@media (max-width:900px){
  .page-root{--maxw:100%;--pad-x:22px}
  .page-root .product-grid,.page-root .team-wall,.page-root .stat-row{grid-template-columns:1fr!important}
  .page-root .hero{padding-top:48px;padding-bottom:34px}
}
"""

uri = Ezagent.URI.session("system", :hello, "web")
{:ok, _s, builder} = EzagentPluginHello.App.ensure_app("system", "web")
IO.puts("driving body + shell into session://system/hello/web ...")
EzagentPluginHello.TurnDriver.drive(uri, body, "ruihua v2: full-width bands + ruihua SVGs + live github", builder)
EzagentPluginHello.TurnDriver.set_shell(uri, builder, "", theme_css)
IO.puts("waiting for async publish (13s)...")
Process.sleep(13_000)
IO.puts("done.")

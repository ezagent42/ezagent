import {Suspense, lazy, useEffect, useState} from "react"
import {ExternalLink, GitPullRequest, Hand, Paperclip, Pencil, Plus, RefreshCw, Scissors, Send, Trash2} from "lucide-react"

import {Badge, Button} from "../../../ezagent_plugin_world/assets/src/components/ui/primitives"
import {KanbanCanvas, STAGE_LABEL, STAGES, gateVerdict} from "./KanbanCanvas"

// 懒加载：excalidraw 组件 + 它的 CSS 都进独立 chunk，不撑主包。
const ExcalidrawModal = lazy(() => import("./ExcalidrawModal").then((m) => ({default: m.ExcalidrawModal})))

const STATUS_ICON: Record<string, string> = {unassigned: "○", claimed: "◔", doing: "◑", done: "●"}

type Node = {
  parent_id: string | null
  title: string
  order: number
  stage: string | null
  owner: string | null
  status: string | null
  artifacts?: Record<string, unknown>[]
  metrics?: Record<string, unknown>[]
  ci?: {score: number; max: number; markdown: string; criteria: {name: string; ok: boolean}[]}
}

type DropEntry = {title?: string; stage?: string; reason?: string; count?: number}
type Tree = {nodes: Record<string, Node>; root_id: string | null; drops?: DropEntry[]}

export type KanbanState = {
  component?: string
  kanban_uri?: string | null
  instances?: {uri: string; name: string; path: string}[]
  tree?: Tree | null
  stages?: string[]
  statuses?: string[]
  miro_board_url?: string | null
  miro?: {configured?: boolean; board_id?: string | null}
  // 每图独立配置（github 仓库=纯数据拼 git 链接 + miro 板名；GitHub 主动连接器已退役）
  config?: {github_repo?: string | null; miro_board?: string | null}
  last_dispatch_status?: string | null
  // 分享看板生成的只读接收链接（kanban.share_board 成功后经 world:state 回推）。
  share_link?: string | null
}

type Act = (action: string, args: Record<string, unknown>) => void

const inputCls =
  "rounded-md border border-border bg-background px-2.5 py-1.5 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"

type UploadFn = (file: File) => Promise<{grant: string; name: string} | null>

export function Kanban({
  state,
  onAction = () => undefined,
  onShare,
  onShareArtifact,
  onUploadFile,
  mode = "operate",
}: {
  state: KanbanState
  onAction?: Act
  // 分享看板：拿到本图 uri → 交给宿主 dispatch kanban.share_board（回推 share_link）。
  onShare?: (kanbanUri: string) => void
  onShareArtifact?: (name: string, url: string) => void
  onUploadFile?: UploadFn
  // "operate"（默认，会话 tab 用）：有 kanban_uri 就渲富操作面 KanbanDetail。
  // "config"（插件页 /plugins/kanban 用）：只渲配置面 KanbanList（Miro/GitHub 凭证），
  // 不出操作 UI——建树/认领/编辑都在会话 tab 里做。白名单不动（tab 走同一 dispatch）。
  mode?: "operate" | "config"
}) {
  if (mode === "config") return <KanbanList state={state} onAction={onAction} />
  return state.kanban_uri ? (
    <KanbanDetail state={state} onAction={onAction} onShare={onShare} onShareArtifact={onShareArtifact} onUploadFile={onUploadFile} />
  ) : (
    // 空会话 tab（零块板）：给「建第一块板」入口（showCreate），不再只有 Miro 配置。
    <KanbanList state={state} onAction={onAction} showCreate />
  )
}

// 插件配置页 = 只配 Miro 凭证（不在这编辑导图——编辑在会话内 Kanban 子视图）。
// showCreate=true（空会话 tab）时，顶部多出「建第一块板」入口——否则用户在零板空态
// 里无从 UI 建板（建板输入原本只在 KanbanDetail 侧边栏，得先有板才能进）。
function KanbanList({state, onAction, showCreate = false}: {state: KanbanState; onAction: Act; showCreate?: boolean}) {
  const [token, setToken] = useState("")
  const [newName, setNewName] = useState("")
  const configured = state.miro?.configured
  const createBoard = () => {
    const name = newName.trim()
    if (!name) return
    onAction("kanban.create", {name})
    setNewName("")
  }
  return (
    <div className="flex max-w-2xl flex-col gap-4 p-6">
      {showCreate && (
        <div className="flex flex-col gap-3 rounded-md border border-border bg-card p-4" data-world-kanban-empty-create>
          <div>
            <h2 className="text-lg font-semibold text-foreground">看板 · 新建</h2>
            <p className="text-sm text-muted-foreground">这个会话还没有看板。建一块开始——建完自动进操作面。<strong>建议英文/数字/连字符命名</strong>（中文可能被拒）。</p>
          </div>
          <div className="flex gap-2">
            <input
              className={`${inputCls} w-full`}
              placeholder="新看板名（如 my-product-board）"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && createBoard()}
            />
            <Button type="button" size="sm" onClick={createBoard}>
              <Plus className="h-4 w-4" /> 建看板
            </Button>
          </div>
        </div>
      )}
      <div>
        <h2 className="text-lg font-semibold text-foreground">看板 · 配置</h2>
        <p className="text-sm text-muted-foreground">配置出站连接器凭证（Miro）。<strong>建树/认领/编辑在会话(session)里的 Kanban 子视图</strong>，本页只配置。</p>
      </div>
      <div className="flex flex-col gap-3 rounded-md border border-border bg-card p-4">
        <div className="flex items-center gap-2">
          <span className="font-medium text-foreground">Miro 凭证</span>
          {configured ? (
            <span className="rounded bg-muted px-1.5 py-0.5 text-xs text-green-600 dark:text-green-400">已配置 ✓</span>
          ) : (
            <span className="rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">未配置</span>
          )}
        </div>
        <label className="flex flex-col gap-1 text-xs text-muted-foreground">
          Access Token
          <input type="password" className={`${inputCls} w-full`} placeholder="粘贴 Miro access token" value={token} onChange={(e) => setToken(e.target.value)} />
        </label>
        <div>
          <Button type="button" size="sm" onClick={() => token.trim() && onAction("kanban.save_miro_creds", {access_token: token.trim()})}>
            保存凭证
          </Button>
        </div>
      </div>

      <p className="text-xs text-muted-foreground">凭证存到 system://credentials/*.yaml（节点级，0600，仅 admin 可改，不写死）。GitHub 出站已退役——gh 连通是 agent 的 CLI 行为。</p>
      <Status state={state} />
    </div>
  )
}

function KanbanDetail({state, onAction, onShare, onShareArtifact, onUploadFile}: {state: KanbanState; onAction: Act; onShare?: (kanbanUri: string) => void; onShareArtifact?: (name: string, url: string) => void; onUploadFile?: UploadFn}) {
  const uri = state.kanban_uri as string
  const tree = state.tree || {nodes: {}, root_id: null}
  const statuses = state.statuses || ["claimed", "doing", "done"]
  const instances = state.instances || []
  const drops = tree.drops || []
  const nodeCount = Object.keys(tree.nodes).length
  const [rootTitle, setRootTitle] = useState("")
  const [newName, setNewName] = useState("")
  const [selectedId, setSelectedId] = useState<string | null>(tree.root_id)
  // 本图配置（全图属性，侧边栏内联可见可编辑）
  const [cfgRepo, setCfgRepo] = useState(state.config?.github_repo || "")
  const [cfgMiro, setCfgMiro] = useState(state.config?.miro_board || "")

  // 切 board / 树变化后，选中节点若已不存在则回退到根
  useEffect(() => {
    if (selectedId && !tree.nodes[selectedId]) setSelectedId(tree.root_id)
  }, [tree, selectedId])

  const sel = selectedId ? tree.nodes[selectedId] : null
  const nodeArgs = selectedId ? {kanban_uri: uri, id: selectedId} : {}
  // R1.1 前端校验：stage 只能选"父棒或父棒+1"（根固定 positioning），跟后端一致——
  // 不让用户选了再被拒。
  const allowedStages: string[] = !sel
    ? []
    : !sel.parent_id
      ? ["positioning"]
      : (() => {
          const parent = tree.nodes[sel.parent_id as string]
          const pi = STAGES.indexOf(parent?.stage || "positioning")
          return [STAGES[pi], STAGES[pi + 1]].filter(Boolean) as string[]
        })()

  return (
    <div className="flex h-full flex-col gap-4 p-5" data-world-kanban-workbench>
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border pb-4">
        <div className="min-w-0">
          <div className="mb-1 flex items-center gap-2">
            <span className="font-mono text-[10px] font-semibold uppercase tracking-[0.16em] text-muted-foreground">Kanban workspace</span>
            <Badge tone="primary">当前看板</Badge>
          </div>
          <h2 className="truncate text-xl font-semibold tracking-tight text-foreground">{uri.split("/").pop()}</h2>
          <p className="mt-1 text-xs text-muted-foreground">{nodeCount} 个节点 · 从定位到 PR 的接力图</p>
          {(state.config?.github_repo || state.config?.miro_board) && (
            <p className="truncate text-xs text-muted-foreground">
              {state.config?.github_repo && <>GitHub: {state.config.github_repo}</>}
              {state.config?.github_repo && state.config?.miro_board && " · "}
              {state.config?.miro_board && <>Miro: {state.config.miro_board}</>}
            </p>
          )}
        </div>
        <div className="flex flex-shrink-0 items-center gap-1.5">
          {onShare && (
            <Button type="button" size="sm" variant="secondary" title="生成只读分享链接" onClick={() => onShare(uri)}>
              <Send className="h-4 w-4" /> 分享
            </Button>
          )}
          <Button type="button" size="sm" variant="secondary" title="同步到 Miro（建/复用本图对应的板）" onClick={() => onAction("kanban.sync_miro", {kanban_uri: uri})}>
            <RefreshCw className="h-4 w-4" /> Miro
          </Button>
        </div>
      </header>
      {state.miro_board_url && (
        <a className="inline-flex items-center gap-1 text-sm text-primary hover:underline" href={state.miro_board_url} target="_blank" rel="noreferrer">
          <ExternalLink className="h-3.5 w-3.5" /> 打开 Miro 看板
        </a>
      )}

      {/* 校验拒绝的醒目提示(中文)——last_dispatch_status 是 error 时显示红横幅 */}
      {dispatchError(state.last_dispatch_status) && (
        <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          <span>⚠</span>
          <span>{dispatchError(state.last_dispatch_status)}</span>
        </div>
      )}

      {/* 画布区固定高度（不动 session 布局即可根治"左栏一长把画布滚出视野"）：
          KanbanDetail 高度=header+这块固定高，不随左栏内容增长→外层 board 不滚→画布常驻。
          左栏在这固定高内 overflow-y-auto 自己滚。 */}
      <div className="flex h-[min(720px,calc(100vh-15rem))] min-h-[560px] gap-4 overflow-hidden">
        {/* 侧边栏：导图列表 + 本图配置 + drop历史 + 节点属性（整栏在固定高内滚动，宽松；不带动画布） */}
        <aside className="flex w-80 flex-shrink-0 flex-col gap-3 overflow-y-auto rounded-xl border border-border bg-muted/25 p-2.5 pr-1.5" aria-label="kanban control panel">
          <div className="flex-shrink-0 rounded-lg border border-border bg-card p-3 shadow-sm">
            <div className="mb-1.5 text-xs font-semibold text-muted-foreground">导图</div>
            <ul className="flex max-h-32 flex-col gap-0.5 overflow-y-auto">
              {instances.map((i) => (
                <li key={i.uri}>
                  <button
                    type="button"
                    onClick={() => onAction("kanban.select_board", {kanban_uri: i.uri})}
                    className={`w-full truncate rounded-md border px-2 py-1.5 text-left text-sm transition ${i.uri === state.kanban_uri ? "border-primary/25 bg-primary/10 font-medium text-foreground shadow-sm" : "border-transparent text-muted-foreground hover:border-border hover:bg-muted"}`}
                  >
                    {i.name}
                  </button>
                </li>
              ))}
            </ul>
            <div className="mt-2 flex gap-1">
              <input className={`${inputCls} w-full`} placeholder="新导图名" value={newName} onChange={(e) => setNewName(e.target.value)} />
              <Button type="button" size="sm" onClick={() => newName.trim() && (onAction("kanban.create", {name: newName.trim()}), setNewName(""))}>
                <Plus className="h-4 w-4" />
              </Button>
            </div>
          </div>

          {/* 本图配置（全图属性，内联可见可编辑）——repo/miro板名按图配；token 在全局 */}
          <div className="flex flex-shrink-0 flex-col gap-2.5 rounded-lg border border-border bg-card p-3 shadow-sm">
            <div className="text-xs font-semibold text-muted-foreground">本图配置</div>
            <label className="flex flex-col gap-1 text-xs text-muted-foreground">
              GitHub 仓库（owner/name）
              <input className={`${inputCls} w-full`} placeholder="如 jjkysy/test-ezagent" value={cfgRepo} onChange={(e) => setCfgRepo(e.target.value)} />
            </label>
            <label className="flex flex-col gap-1 text-xs text-muted-foreground">
              Miro 板名（按名字，id 看不见）
              <input className={`${inputCls} w-full`} placeholder="如 我的产品看板" value={cfgMiro} onChange={(e) => setCfgMiro(e.target.value)} />
            </label>
            <div>
              <Button type="button" size="sm" onClick={() => onAction("kanban.set_board_config", {kanban_uri: uri, github_repo: cfgRepo.trim(), miro_board: cfgMiro.trim()})}>
                保存本图配置
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">GitHub token 在 Plugins → 看板 全局配。</p>
          </div>

          {/* drop 历史（全图属性）：任何棒 drop 都记一条，全图可见，不挂某个节点 */}
          {drops.length > 0 && (
            <div className="flex flex-shrink-0 flex-col rounded-lg border border-border bg-card p-3 shadow-sm">
              <div className="mb-1.5 text-xs font-semibold text-muted-foreground">drop 历史（{drops.length}）</div>
              <ul className="flex flex-col gap-1 text-xs">
                {drops.map((d, i) => (
                  <li key={i} className="flex items-start gap-1.5 rounded bg-amber-50 px-1.5 py-1 text-amber-700 dark:bg-amber-950/30 dark:text-amber-400">
                    <Scissors className="mt-0.5 h-3 w-3 flex-shrink-0" />
                    <span className="flex-1 break-words">
                      [{STAGE_LABEL[d.stage || ""] || d.stage}] {d.title} · 砍 {d.count} 节点{d.reason ? ` · ${d.reason}` : ""}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="flex flex-shrink-0 flex-col rounded-lg border border-border bg-card p-3 shadow-sm">
            <div className="mb-1.5 text-xs font-semibold text-muted-foreground">节点属性</div>
            {sel ? (
              <NodePanel node={sel} args={nodeArgs} stages={allowedStages} statuses={statuses} onAction={onAction} onShareArtifact={onShareArtifact} onUploadFile={onUploadFile} />
            ) : (
              <p className="text-xs text-muted-foreground">点画布里的节点查看/编辑属性。</p>
            )}
          </div>
        </aside>

        {/* 画布 */}
        <div className="relative flex-1 overflow-hidden rounded-xl border border-border bg-[radial-gradient(circle_at_top_left,hsl(var(--primary)/0.09),transparent_30%),linear-gradient(hsl(var(--muted)/0.35)_1px,transparent_1px),linear-gradient(90deg,hsl(var(--muted)/0.35)_1px,transparent_1px)] bg-[size:auto,24px_24px,24px_24px]" data-world-kanban-canvas>
          {!tree.root_id ? (
            <div className="flex h-full items-center justify-center p-6" data-world-kanban-empty-tree>
              <div className="w-full max-w-md rounded-xl border border-border bg-card p-5 shadow-lg">
                <span className="font-mono text-[10px] font-semibold uppercase tracking-[0.16em] text-primary">01 / 建立起点</span>
                <h3 className="mt-2 text-lg font-semibold text-foreground">给这张看板一个明确的发心</h3>
                <p className="mt-1 text-sm leading-relaxed text-muted-foreground">根节点会成为后续定位、指标、痛点和功能接力的共同起点。</p>
                <div className="mt-4 flex gap-2">
                  <input className={`${inputCls} min-w-0 flex-1`} placeholder="根节点标题（产品发心）" value={rootTitle} onChange={(e) => setRootTitle(e.target.value)} />
                  <Button type="button" size="sm" onClick={() => rootTitle.trim() && (onAction("kanban.add_node", {kanban_uri: uri, parent_id: "", title: rootTitle.trim()}), setRootTitle(""))}>
                <Plus className="h-4 w-4" /> 建根
                  </Button>
                </div>
              </div>
            </div>
          ) : (
            <>
              <div className="pointer-events-none absolute left-4 top-4 z-10 max-w-xs rounded-lg border border-border/80 bg-card/90 px-3 py-2 shadow-sm backdrop-blur">
                <p className="text-xs font-semibold text-foreground">结构画布</p>
                <p className="mt-0.5 text-[11px] leading-relaxed text-muted-foreground">{nodeCount === 1 ? "从根节点添加下一棒，开始铺开接力图。" : "点击节点查看属性；用节点右侧 + 号继续展开。"}</p>
              </div>
              <KanbanCanvas uri={uri} tree={tree} selectedId={selectedId} onSelectNode={setSelectedId} onAction={onAction} />
            </>
          )}
        </div>
      </div>
      <Status state={state} />
    </div>
  )
}

// 选中节点的属性面板（侧边栏）：认领 / 状态 / 阶段 / 产物 / 指标 / 改名 / 删除。
function NodePanel({node, args, stages, statuses, onAction, onShareArtifact, onUploadFile}: {
  node: Node
  args: Record<string, unknown>
  stages: string[]
  statuses: string[]
  onAction: Act
  onShareArtifact?: (name: string, url: string) => void
  onUploadFile?: UploadFn
}) {
  const owner = node.owner ? node.owner.split("/").pop() : null
  const selectCls = "rounded border border-border bg-background px-1 py-0.5 text-xs text-muted-foreground"
  // issue2: inline content 用 textarea 编辑器(替 window.prompt 单行 hack)
  const [editing, setEditing] = useState(false)
  const [cName, setCName] = useState("")
  const [cBody, setCBody] = useState("")
  // 内嵌 excalidraw 画板：{initial: 已有scene或null, readOnly}；null=不开
  const [excal, setExcal] = useState<{initial: string | null; readOnly: boolean} | null>(null)
  return (
    <div className="flex flex-col gap-2 text-sm">
      <div className="font-medium text-foreground">{node.title}</div>
      <div className="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
        <span>{STATUS_ICON[node.status || "unassigned"]} {node.status || "未认领"}</span>
        {node.stage && <span className="rounded bg-muted px-1 text-primary">{STAGE_LABEL[node.stage] || node.stage}</span>}
        {owner && <span>@{owner}</span>}
      </div>
      {(() => {
        // 片4 gate 软门：派生评价（不拦 status，纯提示）
        const gv = gateVerdict(node)
        if (gv.verdict === "none") return null
        return (
          <div className={`text-xs ${gv.verdict === "pass" ? "text-green-600" : "text-amber-600"}`}>
            {gv.verdict === "pass" ? "✓ 本棒已过 gate" : `⚠ gate 未过：${gv.reason}`}
          </div>
        )
      })()}
      {/* 片5 CI 评价：pr 节点沿祖先链算 上游done/Gherkin/issue/test绿 → 评分 + 逐条 */}
      {node.ci && (
        <div className="rounded-md border border-border bg-muted/30 p-2 text-xs">
          <div className="font-semibold text-foreground">CI 评价 {node.ci.score}/{node.ci.max}</div>
          <ul className="mt-0.5 flex flex-col gap-0.5">
            {node.ci.criteria.map((c, i) => (
              <li key={i} className={c.ok ? "text-green-600" : "text-amber-600"}>{c.ok ? "✓" : "○"} {c.name}</li>
            ))}
          </ul>
        </div>
      )}
      <div className="flex items-center gap-1.5">
        <Button type="button" size="sm" variant="secondary" title="给本节点加一个子节点（接力链下一棒）" onClick={() => {
          const t = window.prompt("子节点标题（接力链下一棒，如 北极星指标）")
          if (t && t.trim()) onAction("kanban.add_node", {kanban_uri: args.kanban_uri, parent_id: args.id, title: t.trim()})
        }}>
          <Plus className="h-3.5 w-3.5" /> 加子
        </Button>
        <Button type="button" size="sm" variant="secondary" onClick={() => onAction("kanban.claim_node", args)}>
          <Hand className="h-3.5 w-3.5" /> 认领
        </Button>
      </div>
      <div className="flex items-center gap-3 text-xs text-muted-foreground">
        <label className="flex items-center gap-1">
          状态
          {/* 回显当前值(issue1: 改完看得到) */}
          <select className={selectCls} value={statuses.includes(node.status || "") ? node.status || "" : ""} onChange={(e) => e.target.value && onAction("kanban.set_status", {...args, status: e.target.value})}>
            <option value="">—</option>
            {statuses.map((s) => (<option key={s} value={s}>{s}</option>))}
          </select>
        </label>
        <label className="flex items-center gap-1">
          阶段
          <select className={selectCls} value={node.stage || ""} onChange={(e) => e.target.value && onAction("kanban.set_stage", {...args, stage: e.target.value})}>
            <option value="">—</option>
            {stages.map((s) => (<option key={s} value={s}>{STAGE_LABEL[s] || s}</option>))}
          </select>
        </label>
      </div>
      <div>
        <div className="text-xs font-semibold text-muted-foreground">产物（{node.artifacts?.length ?? 0}）</div>
        <ul className="flex flex-col gap-1 text-xs">
          {(node.artifacts ?? []).map((raw, i) => {
            const a = raw as {kind?: string; ref?: string; url?: string; content?: string}
            const name = a.ref || a.kind || "artifact"
            // drop 记录：单独显眼显示(✂ + 原因全文)，这是被砍子树反哺过来的历史
            if (a.kind === "drop_record") {
              return (
                <li key={i} className="flex items-start gap-1.5 rounded bg-amber-50 px-1.5 py-1 text-amber-700 dark:bg-amber-950/30 dark:text-amber-400">
                  <Scissors className="mt-0.5 h-3 w-3 flex-shrink-0" />
                  <span className="flex-1 break-words">{a.content || name}</span>
                </li>
              )
            }
            return (
              <li key={i} className="flex items-center gap-1.5">
                <Paperclip className="h-3 w-3 flex-shrink-0 text-muted-foreground" />
                <span className="flex-1 truncate text-foreground" title={a.content || name}>{name}</span>
                {a.kind === "excalidraw" && a.content ? (
                  <button type="button" className="text-primary hover:underline" onClick={() => setExcal({initial: a.content || null, readOnly: true})}>
                    看图
                  </button>
                ) : (
                  a.content && <span title={a.content}>📄</span>
                )}
                {a.url && (
                  <a href={a.url} target="_blank" rel="noreferrer" className="text-primary hover:underline">打开</a>
                )}
                {onShareArtifact && (
                  <button type="button" className="text-primary hover:underline" onClick={() => onShareArtifact(name, a.url || "")}>
                    发对话
                  </button>
                )}
              </li>
            )
          })}
        </ul>
        {editing ? (
          <div className="mt-1 flex flex-col gap-1">
            <input className={`${inputCls} w-full`} placeholder="产物名（如 Gherkin 验收）" value={cName} onChange={(e) => setCName(e.target.value)} />
            <textarea
              className="h-28 w-full rounded-md border border-border bg-background px-2 py-1 font-mono text-xs text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
              placeholder={"markdown 内容（存 ezagent 真相源，CI 可读）\nGiven …\nWhen …\nThen …"}
              value={cBody}
              onChange={(e) => setCBody(e.target.value)}
            />
            <div className="flex items-center gap-2">
              <Button
                type="button"
                size="sm"
                onClick={() => {
                  if (cName.trim() && cBody.trim()) {
                    onAction("kanban.attach_artifact", {...args, artifact: {tool: "inline", kind: "spec", ref: cName.trim(), content: cBody}})
                    setCName("")
                    setCBody("")
                    setEditing(false)
                  }
                }}
              >
                保存
              </Button>
              <button type="button" className="text-xs text-muted-foreground hover:underline" onClick={() => setEditing(false)}>
                取消
              </button>
            </div>
          </div>
        ) : (
          <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1.5 text-xs">
            <span className="text-muted-foreground">挂：</span>
            <button
              type="button"
              className="inline-flex items-center gap-1 text-primary hover:underline"
              onClick={() => {
                const name = window.prompt("链接产物名（如 github PR #1）")
                if (!name) return
                const url = window.prompt("URL（可分享链接，别填本地路径）") || ""
                onAction("kanban.attach_artifact", {...args, artifact: {tool: "ref", kind: "link", ref: name, url}})
              }}
            >
              <Paperclip className="h-3 w-3" /> 加链接
            </button>
            <button type="button" className="inline-flex items-center gap-1 text-primary hover:underline" onClick={() => setEditing(true)}>
              📄 加内容
            </button>
            {onUploadFile && (
              <label className="inline-flex cursor-pointer items-center gap-1 text-primary hover:underline">
                <Paperclip className="h-3 w-3" /> 上传文件
                <input
                  type="file"
                  className="hidden"
                  onChange={async (e) => {
                    const file = e.target.files?.[0]
                    e.target.value = ""
                    if (!file) return
                    const r = await onUploadFile(file)
                    if (r) onAction("kanban.attach_upload", {...args, grant: r.grant, name: r.name})
                  }}
                />
              </label>
            )}
            <button type="button" className="inline-flex items-center gap-1 text-primary hover:underline" onClick={() => setExcal({initial: null, readOnly: false})}>
              ✏️ 画图
            </button>
            <button
              type="button"
              className="inline-flex items-center gap-1 text-primary hover:underline"
              title="挂仓库里某个文件（填 commit SHA + 路径 → 永久可点跳转的 github 链接）"
              onClick={() => {
                const sha = window.prompt("commit SHA（github 文件链接里的那段哈希，钉它=永久，merge/删分支后也能开）")
                if (!sha || !sha.trim()) return
                const path = window.prompt("文件路径（如 docs/discuss/1-homesite/P-用户画像-personas.md）")
                if (path && path.trim()) onAction("kanban.attach_code_file", {...args, sha: sha.trim(), path: path.trim()})
              }}
            >
              <Paperclip className="h-3 w-3" /> 挂代码文件
            </button>
          </div>
        )}
      </div>
      {excal && (
        <Suspense fallback={null}>
          <ExcalidrawModal
            initial={excal.initial}
            readOnly={excal.readOnly}
            onSave={(json) => onAction("kanban.attach_artifact", {...args, artifact: {tool: "excalidraw", kind: "excalidraw", ref: "线框图", content: json}})}
            onClose={() => setExcal(null)}
          />
        </Suspense>
      )}
      <div className="flex flex-wrap gap-2 border-t border-border pt-2 text-xs">
        {/* pr 棒：登记 PR（纯数据：把 PR 链接挂到节点；GitHub 主动出站已退役） */}
        {node.stage === "pr" && (
          <button
            type="button"
            className="inline-flex items-center gap-1 text-primary hover:underline"
            title="登记一个已开的 PR 到本节点（拼链接挂节点，不出站）"
            onClick={() => {
              const pr = window.prompt("已开 PR 的编号（如 42）")
              if (pr && pr.trim()) onAction("kanban.register_pr", {...args, pr: pr.trim()})
            }}
          >
            <GitPullRequest className="h-3 w-3" /> 登记 PR
          </button>
        )}
        <button
          type="button"
          className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
          onClick={() => {
            const t = window.prompt("新标题", node.title)
            if (t) onAction("kanban.rename_node", {...args, title: t})
          }}
        >
          <Pencil className="h-3 w-3" /> 改名
        </button>
        <button
          type="button"
          className="inline-flex items-center gap-1 text-destructive hover:underline"
          onClick={() => onAction("kanban.remove_node", args)}
        >
          <Trash2 className="h-3 w-3" /> 删除
        </button>
        <button
          type="button"
          className="inline-flex items-center gap-1 text-amber-600 hover:underline"
          title="指标不达标→砍整个子树+反哺最近痛点"
          onClick={() => {
            const reason = window.prompt("drop 原因（指标不达标说明）")
            if (reason !== null) onAction("kanban.drop_subtree", {...args, reason})
          }}
        >
          <Scissors className="h-3 w-3" /> drop
        </button>
      </div>
    </div>
  )
}

// 校验/操作失败码 → 中文（顶部红横幅用；返回 null 表示不是错误）
const DISPATCH_ERR: Record<string, string> = {
  forbidden: "无权限：节点已被他人认领，只有 owner 或 admin 能改",
  must_claim_first: "请先认领该节点，再改状态",
  already_claimed: "该节点已被他人认领",
  stage_order_violation: "阶段不合法：只能是父节点的阶段或下一阶段（固定接力链，不能跳棒/回退）",
  invalid_stage: "无效阶段",
  invalid_status: "无效状态",
  node_not_found: "节点不存在",
  parent_not_found: "父节点不存在",
  would_create_cycle: "不能移动成自己的子孙（会成环）",
  bad_kanban_uri: "导图地址无效",
  unauthorized: "无权限（该操作需 admin）",
  no_caller: "缺调用者身份",
  name_required: "名称不能为空",
  invalid_workspace: "工作区无效",
  access_token_required: "缺 Miro access token",
  github_repo_missing: "GitHub 仓库未配置：去本图配置填 owner/name（拼链接用）",
  bad_pr_number: "PR 号无效：填数字，如 42",
}
function dispatchError(status?: string | null): string | null {
  if (!status || !status.startsWith("error:")) return null
  const code = status.slice("error:".length)
  return DISPATCH_ERR[code] || `操作失败：${code}`
}

function Status({state}: {state: KanbanState}) {
  const s = state.last_dispatch_status
  if (!s) return null
  if (s === "ok") return <p className="mt-2 text-xs text-green-600">✓ 已保存</p>
  if (dispatchError(s)) return null // 错误已在顶部横幅显示
  return <p className="mt-2 text-xs text-muted-foreground">· {s}</p>
}

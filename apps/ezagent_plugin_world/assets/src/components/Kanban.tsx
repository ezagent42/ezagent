import {Suspense, lazy, useEffect, useRef, useState, type ReactNode} from "react"
import {ExternalLink, GitPullRequest, Hand, Paperclip, Plus, RefreshCw, Scissors, Send, Trash2} from "lucide-react"

import {Button} from "./ui/primitives"
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
  // ㉕ 非破坏 drop 标（北极星不达标跟踪，节点保留；后端整棵子树都带标）
  dropped?: boolean
}

// ㉕ 后 drop 历史 = %{id, reason, at, by}（图级，id 指向被 drop 的子树根）；
// title/stage/count 是旧快照（drop 曾是删除）遗留的历史条目形状，渲染兼容两代。
type DropEntry = {id?: string; reason?: string; at?: string; by?: string; title?: string; stage?: string; count?: number}
type Tree = {nodes: Record<string, Node>; root_id: string | null; drops?: DropEntry[]}

export type KanbanState = {
  component?: string
  kanban_uri?: string | null
  // owned = 登录者是板主人（data_owner）——⑲ 只对自己是版主的板出删除入口
  instances?: {uri: string; name: string; path: string; owned?: boolean}[]
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
  // 登录者身份 URI（session tab 的 conversation state 自带；插件配置面没有也无妨——
  // 配置面不出节点操作 UI）。协作模型规则 3/4 的「自己认领的节点」判定用它。
  caller_uri?: string | null
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
  // "config"（插件页 /plugins/kanban 用）：只渲配置面 KanbanList（Miro 凭证；GitHub
  // 走独立 gh 插件，看板不登记 token），不出操作 UI——建树/认领/编辑都在会话 tab 里做。
  // 白名单不动（tab 走同一 dispatch）。
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
// showCreate=true（空会话 tab）时只渲「建第一块板」入口——凭证登记不出现在会话面
// （去 gh 决策 2：token 只在插件配置面填，板侧不登记任何 token）。
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
  // 空会话 tab：只给建板入口，不出凭证 UI（凭证在 Plugins → 看板 配置面）。
  if (showCreate) {
    return (
      <div className="flex max-w-2xl flex-col gap-4 p-6">
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
        <Status state={state} />
      </div>
    )
  }
  return (
    <div className="flex max-w-2xl flex-col gap-4 p-6">
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

      <p className="text-xs text-muted-foreground">凭证存到 system://credentials/*.yaml（节点级，0600，仅 admin 可改，不写死）。GitHub 集成已移出看板插件——走独立 gh 插件（建设中），看板只保留 repo/PR/SHA 纯数据链接。</p>
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
  const [rootTitle, setRootTitle] = useState("")
  const [newName, setNewName] = useState("")
  const [selectedId, setSelectedId] = useState<string | null>(tree.root_id)

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
    <div className="flex h-full flex-col gap-3 p-5">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="truncate text-base font-semibold text-foreground">看板 · {uri.split("/").pop()}</h2>
        </div>
        <div className="flex flex-shrink-0 items-center gap-1.5">
          {onShare && (
            <Button type="button" size="sm" variant="secondary" title="生成只读分享链接" onClick={() => onShare(uri)}>
              <Send className="h-4 w-4" /> 分享
            </Button>
          )}
          <Button
            type="button"
            size="sm"
            variant="secondary"
            title="同步到 Miro（弹框填板名，建/复用同名板）"
            onClick={() => {
              // 去 gh 决策 2：同步时临时填板名（不再持久登记 mirror 配置）。
              // name 随 args 传给 sync_miro；后端暂不收也无害（world 侧按 kanban_uri 匹配）。
              const name = window.prompt("同步到 Miro 的板名（建/复用同名板）", state.config?.miro_board || "")
              if (name === null) return
              const trimmed = name.trim()
              onAction("kanban.sync_miro", trimmed ? {kanban_uri: uri, name: trimmed} : {kanban_uri: uri})
            }}
          >
            <RefreshCw className="h-4 w-4" /> Miro
          </Button>
        </div>
      </div>
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
      <div className="flex h-[560px] gap-3 overflow-hidden">
        {/* 侧边栏：导图列表 + 本图配置 + drop历史 + 节点属性（整栏在固定高内滚动，宽松；不带动画布） */}
        <aside className="flex w-72 flex-shrink-0 flex-col gap-3 overflow-y-auto pr-1">
          <div className="flex-shrink-0 rounded-md border border-border p-2">
            <div className="mb-1.5 text-xs font-semibold text-muted-foreground">导图</div>
            <ul className="flex max-h-32 flex-col gap-0.5 overflow-y-auto">
              {instances.map((i) => (
                <li key={i.uri} className="group flex items-center gap-1">
                  <button
                    type="button"
                    onClick={() => onAction("kanban.select_board", {kanban_uri: i.uri})}
                    className={`min-w-0 flex-1 truncate rounded px-2 py-1 text-left text-sm ${i.uri === state.kanban_uri ? "bg-accent font-medium text-foreground" : "text-muted-foreground hover:bg-muted"}`}
                  >
                    {i.name}
                  </button>
                  {/* ⑲ 删板入口：只对自己是版主(data_owner)的板显示；确认后走
                      kanban.delete_board(后端 caller==data_owner + Manage cap 校验兜底)。 */}
                  {i.owned && (
                    <button
                      type="button"
                      className="flex-shrink-0 rounded p-1 text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
                      title={`删除看板「${i.name}」（退休板 agent + 清挂载，不可恢复）`}
                      data-world-kanban-delete-board
                      onClick={() =>
                        window.confirm(`删除看板「${i.name}」？\n\n板 agent 将退休、所有会话里的挂载会被清掉，不可恢复。`) &&
                        onAction("kanban.delete_board", {kanban_uri: i.uri})
                      }
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  )}
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

          {/* ㉓ 「本图配置」块已整体移除：GitHub 仓库不在板侧配置（挂 PR/代码统一收束到
              「链接」产物）；Miro 板名只在「同步到 Miro」弹框临时填（set_board_config
              动作后端保留，只撤 UI 入口）。 */}

          {/* drop 历史（全图属性）：任何棒 drop 都记一条，全图可见，不挂某个节点。
              ㉕ 后 drop = 非破坏标记：新条目 %{id, reason, at, by}，节点还在树里。 */}
          {drops.length > 0 && (
            <div className="flex flex-shrink-0 flex-col rounded-md border border-border p-2">
              <div className="mb-1.5 text-xs font-semibold text-muted-foreground">drop 历史（{drops.length}）</div>
              <ul className="flex flex-col gap-1 text-xs">
                {drops.map((d, i) => (
                  <li key={i} className="flex items-start gap-1.5 rounded bg-destructive/10 px-1.5 py-1 text-destructive">
                    <Scissors className="mt-0.5 h-3 w-3 flex-shrink-0" />
                    <span className="flex-1 break-words">{dropEntryLabel(d, tree)}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="flex flex-shrink-0 flex-col rounded-md border border-border p-2">
            <div className="mb-1.5 text-xs font-semibold text-muted-foreground">节点属性</div>
            {sel ? (
              <NodePanel node={sel} args={nodeArgs} stages={allowedStages} statuses={statuses} callerUri={state.caller_uri} dropEntries={dropHistoryFor(tree, selectedId)} onAction={onAction} onShareArtifact={onShareArtifact} onUploadFile={onUploadFile} />
            ) : (
              <p className="text-xs text-muted-foreground">点画布里的节点查看/编辑属性。</p>
            )}
          </div>
        </aside>

        {/* 画布 */}
        <div className="flex-1 overflow-hidden rounded-md border border-border">
          {!tree.root_id ? (
            <div className="flex gap-2 p-4">
              {/* 协作模型 H1：任何成员可建根，建完自动认领给自己（单根先行，已有根后端拒 root_exists）。 */}
              <input className={`${inputCls} w-72`} placeholder="根节点标题（建完自动认领给你）" value={rootTitle} onChange={(e) => setRootTitle(e.target.value)} />
              <Button type="button" size="sm" onClick={() => rootTitle.trim() && (onAction("kanban.add_node", {kanban_uri: uri, parent_id: "", title: rootTitle.trim()}), setRootTitle(""))}>
                <Plus className="h-4 w-4" /> 建根
              </Button>
            </div>
          ) : (
            <KanbanCanvas uri={uri} tree={tree} selectedId={selectedId} onSelectNode={setSelectedId} onAction={onAction} />
          )}
        </div>
      </div>
      {/* ㉞ 「✓已保存」常驻标记已删：kanban 每个动作即时提交，无保存概念；
          失败已有顶部红横幅（dispatchError），成功不再渲染任何常驻状态。 */}
    </div>
  )
}

// 选中节点的属性面板（侧边栏）——布局按 ㉗ 规格重做（2026-07-16 用户定）：
// * 前两排信息（名称 / 状态·阶段·认领人）+「加子」「认领」两按钮保持，其余一条信息一排。
// * ㉖ 名称 = 面板顶部就地编辑输入框（认领人可编辑；改名不再走 window.prompt）。
// * 产物区 =「添加」+ 下拉框[链接/内容/画图/附件] + 添加按钮；每个产物一个删除按钮
//   （detach_artifact）；「内容」弹大框最简 md 编辑器（照 ExcalidrawModal 模态形态）；
//   挂代码文件/SHA 入口已删（收束到「链接」，attach_code_file 动作后端保留）。
// 协作模型（docs/notes/2026-07-15-kanban-collab-model.md）：
// * 规则 2：未认领节点除「加子」「认领」外不显示任何属性/操作（未认领恒为空，H3）。
// * 规则 3：认领 ↔ 取消认领 toggle；有内容后端拒 has_content_cannot_unclaim。
// * 规则 4：编辑控件只对认领人自己显示（版主由后端兜底放行；state 暂无 board owner
//   字段，前端只按 node owner 判——版主看他人节点为只读展示）。
// * 规则 5：删除 = 删整棵子树；子树含他人认领节点后端拒 forbidden_mixed_ownership。
function NodePanel({node, args, stages, statuses, callerUri, dropEntries = [], onAction, onShareArtifact, onUploadFile}: {
  node: Node
  args: Record<string, unknown>
  stages: string[]
  statuses: string[]
  callerUri?: string | null
  // ㉕ 本节点适用的 drop 记录（自己或祖先被 drop 的理由+历史，KanbanDetail 算好传入）
  dropEntries?: DropEntry[]
  onAction: Act
  onShareArtifact?: (name: string, url: string) => void
  onUploadFile?: UploadFn
}) {
  const owner = node.owner ? node.owner.split("/").pop() : null
  const selectCls = "rounded border border-border bg-background px-1 py-0.5 text-xs text-muted-foreground disabled:cursor-not-allowed disabled:opacity-50"
  // ㉗④「内容」产物：弹大框 md 编辑器（非 null = 开着）
  const [contentOpen, setContentOpen] = useState(false)
  // 内嵌 excalidraw 画板：{initial: 已有scene或null, readOnly}；null=不开
  const [excal, setExcal] = useState<{initial: string | null; readOnly: boolean} | null>(null)
  // ㉗④ 添加产物下拉框当前选项
  const [addKind, setAddKind] = useState("link")
  const [uploadErr, setUploadErr] = useState<string | null>(null)
  const fileRef = useRef<HTMLInputElement | null>(null)
  // ㉖ 名称就地编辑：本地草稿随选中节点/服务端标题同步
  const [title, setTitle] = useState(node.title)
  useEffect(() => setTitle(node.title), [args.id, node.title])
  const unclaimed = !node.owner
  const isMine = !unclaimed && !!callerUri && node.owner === callerUri
  // 编辑权（规则 4）：认领人自己。state 缺 caller_uri 时放开由后端兜底判（会话 tab 总带）。
  const canEdit = !unclaimed && (callerUri ? isMine : true)
  const addChild = () => {
    const t = window.prompt("子节点标题（加完自动认领给你）")
    if (t && t.trim()) onAction("kanban.add_node", {kanban_uri: args.kanban_uri, parent_id: args.id, title: t.trim()})
  }
  const commitTitle = () => {
    const t = title.trim()
    if (!t || t === node.title) return setTitle(node.title)
    onAction("kanban.rename_node", {...args, title: t})
  }
  // ㉗④ 按下拉框选项走各自的添加流
  const addArtifact = () => {
    if (addKind === "link") {
      const name = window.prompt("链接产物名（如 github PR #1）")
      if (!name || !name.trim()) return
      const url = window.prompt("URL（可分享链接，别填本地路径）") || ""
      onAction("kanban.attach_artifact", {...args, artifact: {tool: "ref", kind: "link", ref: name.trim(), url}})
    } else if (addKind === "content") {
      setContentOpen(true)
    } else if (addKind === "excalidraw") {
      setExcal({initial: null, readOnly: false})
    } else if (addKind === "file") {
      fileRef.current?.click()
    }
  }
  // 附件 = 平台 uploads 通道（与 chat 附件同一端点）：拿 grant → attach_upload 挂节点
  const handleFile = async (file: File | undefined) => {
    if (!file || !onUploadFile) return
    setUploadErr(null)
    const r = await onUploadFile(file)
    if (r) onAction("kanban.attach_upload", {...args, grant: r.grant, name: r.name})
    else setUploadErr("上传失败，请重试")
  }

  // ㉕ 已 drop 节点（自己或祖先被标）：面板显示 drop 理由 + 历史
  const dropBanner = node.dropped ? (
    <div className="rounded-md border border-destructive/40 bg-destructive/10 px-2 py-1.5 text-xs text-destructive" data-world-kanban-dropped>
      <div className="font-semibold">已 drop：北极星指标不达标（跟踪标记，节点保留）</div>
      {dropEntries.length > 0 && (
        <ul className="mt-0.5 flex flex-col gap-0.5">
          {dropEntries.map((d, i) => (
            <li key={i}>
              {d.reason || "（未填理由）"}
              {d.by ? ` · @${d.by.split("/").pop()}` : ""}
              {d.at ? ` · ${new Date(d.at).toLocaleString()}` : ""}
            </li>
          ))}
        </ul>
      )}
    </div>
  ) : null

  // 规则 2：未认领节点 = 空容器，只出「加子」「认领」，不显示任何其他属性/操作入口。
  if (unclaimed) {
    return (
      <div className="flex flex-col gap-2 text-sm" data-world-kanban-node-unclaimed>
        <div className="font-medium text-foreground">{node.title}</div>
        <div className="text-xs text-muted-foreground">{STATUS_ICON.unassigned} 未认领</div>
        {dropBanner}
        <p className="text-xs text-muted-foreground">未认领节点没有属性。认领后才有阶段/状态/产物，才能编辑。</p>
        <div className="flex items-center gap-1.5">
          <Button type="button" size="sm" variant="secondary" title="给本节点加一个子节点（加完自动认领给你）" onClick={addChild}>
            <Plus className="h-3.5 w-3.5" /> 加子
          </Button>
          <Button type="button" size="sm" variant="secondary" title="认领本节点（认领后才有属性、才能编辑）" onClick={() => onAction("kanban.claim_node", args)}>
            <Hand className="h-3.5 w-3.5" /> 认领
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-2 text-sm">
      {/* 行1：名称——认领人就地编辑（㉖，替代原底部「改名」prompt） */}
      {canEdit ? (
        <input
          className={`${inputCls} w-full font-medium`}
          value={title}
          title="节点名称（就地编辑，回车/失焦保存）"
          data-world-kanban-node-title
          onChange={(e) => setTitle(e.target.value)}
          onBlur={commitTitle}
          onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()}
        />
      ) : (
        <div className="font-medium text-foreground">{node.title}</div>
      )}
      {/* 行2：状态·阶段·认领人 */}
      <div className="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
        <span>{STATUS_ICON[node.status || "unassigned"]} {node.status || "未认领"}</span>
        {node.stage && <span className="rounded bg-muted px-1 text-primary">{STAGE_LABEL[node.stage] || node.stage}</span>}
        {owner && <span>@{owner}{isMine ? "（我）" : ""}</span>}
      </div>
      {dropBanner}
      {/* 两按钮：加子 / 取消认领（规则 3 toggle——自己的节点出「取消认领」；他人认领的不出按钮。
          有内容（附件/指标）后端拒 has_content_cannot_unclaim → 顶部横幅提示先清空。） */}
      <div className="flex items-center gap-1.5">
        <Button type="button" size="sm" variant="secondary" title="给本节点加一个子节点（任何成员可加，加完自动认领给你）" onClick={addChild}>
          <Plus className="h-3.5 w-3.5" /> 加子
        </Button>
        {canEdit && (
          <Button type="button" size="sm" variant="secondary" title="取消认领（有附件/指标时需先清空）" onClick={() => onAction("kanban.unclaim_node", args)}>
            <Hand className="h-3.5 w-3.5" /> 取消认领
          </Button>
        )}
      </div>
      {!canEdit && (
        <p className="text-xs text-muted-foreground">该节点由 @{owner} 认领——只有认领人（或版主）能编辑。</p>
      )}
      {/* ——以下按 ㉗②：其余一律一条信息一排—— */}
      {(() => {
        // 片4 gate 软门：派生评价（不拦 status，纯提示）
        const gv = gateVerdict(node)
        if (gv.verdict === "none") return null
        return (
          <div className={`text-xs ${gv.verdict === "pass" ? "text-green-600 dark:text-green-400" : "text-amber-600 dark:text-amber-400"}`}>
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
              <li key={i} className={c.ok ? "text-green-600 dark:text-green-400" : "text-amber-600 dark:text-amber-400"}>{c.ok ? "✓" : "○"} {c.name}</li>
            ))}
          </ul>
        </div>
      )}
      <label className="flex items-center gap-2 text-xs text-muted-foreground">
        状态
        {/* 回显当前值(issue1: 改完看得到)；规则 4：仅认领人可改（版主后端兜底） */}
        <select disabled={!canEdit} className={selectCls} value={statuses.includes(node.status || "") ? node.status || "" : ""} onChange={(e) => e.target.value && onAction("kanban.set_status", {...args, status: e.target.value})}>
          <option value="">—</option>
          {statuses.map((s) => (<option key={s} value={s}>{s}</option>))}
        </select>
      </label>
      <label className="flex items-center gap-2 text-xs text-muted-foreground">
        阶段
        <select disabled={!canEdit} className={selectCls} value={node.stage || ""} onChange={(e) => e.target.value && onAction("kanban.set_stage", {...args, stage: e.target.value})}>
          <option value="">—</option>
          {stages.map((s) => (<option key={s} value={s}>{STAGE_LABEL[s] || s}</option>))}
        </select>
      </label>
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
                {/* ㉗④ 每个产物一个删除按钮（detach_artifact 按 ref 匹配——无 ref 的旧数据不出删钮） */}
                {canEdit && a.ref && (
                  <button
                    type="button"
                    className="text-muted-foreground hover:text-destructive"
                    title={`删除产物「${name}」`}
                    onClick={() => window.confirm(`删除产物「${name}」？`) && onAction("kanban.detach_artifact", {...args, ref: a.ref})}
                  >
                    <Trash2 className="h-3 w-3" />
                  </button>
                )}
              </li>
            )
          })}
        </ul>
        {/* ㉗④ 添加产物 =「添加」+ 下拉框[链接/内容/画图/附件] + 添加按钮。
            挂代码文件/SHA 已删（收束到「链接」）；附件走平台 uploads（与 chat 同通道）。 */}
        {canEdit && (
          <div className="mt-1.5 flex items-center gap-1.5 text-xs">
            <span className="text-muted-foreground">添加</span>
            <select className={selectCls} value={addKind} onChange={(e) => setAddKind(e.target.value)} aria-label="产物类型">
              <option value="link">链接</option>
              <option value="content">内容</option>
              <option value="excalidraw">画图</option>
              {onUploadFile && <option value="file">附件</option>}
            </select>
            <Button type="button" size="sm" variant="secondary" onClick={addArtifact}>
              <Plus className="h-3.5 w-3.5" /> 添加
            </Button>
            <input
              ref={fileRef}
              type="file"
              className="hidden"
              aria-hidden="true"
              tabIndex={-1}
              onChange={(e) => {
                const file = e.target.files?.[0]
                e.target.value = ""
                void handleFile(file)
              }}
            />
          </div>
        )}
        {uploadErr && <p className="mt-1 text-xs text-destructive">{uploadErr}</p>}
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
      {contentOpen && (
        <MarkdownModal
          onSave={(name, body) => onAction("kanban.attach_artifact", {...args, artifact: {tool: "inline", kind: "spec", ref: name, content: body}})}
          onClose={() => setContentOpen(false)}
        />
      )}
      {/* 规则 4/5：操作行只对认领人自己出（版主后端兜底）；删除=删整棵子树。
          改名按钮已删（㉖：名称在面板顶部就地编辑）。 */}
      {canEdit && (
        <div className="flex flex-wrap gap-2 border-t border-border pt-2 text-xs">
          {/* pr 棒：登记 PR（纯数据：把 PR 链接挂到节点；GitHub 集成走独立 gh 插件） */}
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
            className="inline-flex items-center gap-1 text-destructive hover:underline"
            title="删掉本节点和整棵子树；子树里有他人认领的节点会被拒"
            onClick={() => onAction("kanban.remove_node", args)}
          >
            <Trash2 className="h-3 w-3" /> 删除（含子树）
          </button>
          {/* ㉕ drop = 非破坏跟踪标记：节点及子树标红保留，不删除；已标过的不再出按钮（幂等 no-op） */}
          {!node.dropped && (
            <button
              type="button"
              className="inline-flex items-center gap-1 text-destructive hover:underline"
              title="标记北极星指标不达标：节点及整棵子树渲红色边框做跟踪，节点保留不删除"
              onClick={() => {
                const reason = window.prompt("drop 理由（哪个指标不达标、为什么）")
                if (reason !== null) onAction("kanban.drop_subtree", {...args, reason})
              }}
            >
              <Scissors className="h-3 w-3" /> drop（标记不达标，不删除）
            </button>
          )}
        </div>
      )}
    </div>
  )
}

// ㉕ drop 历史条目 → 人话（兼容两代形状：新 %{id, reason, at, by} 指向仍在树里的
// 节点；旧 %{title, stage, count} 是 drop 还是删除时代的遗留历史）。
function dropEntryLabel(d: DropEntry, tree: Tree): string {
  if (d.id) {
    const title = tree.nodes[d.id]?.title || d.id
    const when = d.at ? new Date(d.at).toLocaleString() : null
    const by = d.by ? `@${d.by.split("/").pop()}` : null
    return [title, d.reason || "（未填理由）", by, when].filter(Boolean).join(" · ")
  }
  const stage = d.stage ? `[${STAGE_LABEL[d.stage] || d.stage}] ` : ""
  return `${stage}${d.title || ""} · 砍 ${d.count ?? "?"} 节点${d.reason ? ` · ${d.reason}` : ""}`
}

// ㉕ 选中节点适用的 drop 记录：drop 标记打在整棵子树上，但历史条目只记子树根——
// 沿 parent 链向上找「自己或祖先」的条目，即本节点被标红的理由与历史。
function dropHistoryFor(tree: Tree, id: string | null): DropEntry[] {
  if (!id) return []
  const chain = new Set<string>()
  let cur: string | null = id
  let guard = 0
  while (cur && !chain.has(cur) && guard++ < 10000) {
    chain.add(cur)
    cur = tree.nodes[cur]?.parent_id ?? null
  }
  return (tree.drops || []).filter((d) => !!d.id && chain.has(d.id))
}

// ㉗④「内容」产物编辑器：照 ExcalidrawModal 的模态形态（弹大框），最简 md
// 编辑器 = textarea + 只读预览两栏，零新依赖（预览用下方 renderMarkdown 微型渲染）。
function MarkdownModal({onSave, onClose}: {onSave: (name: string, body: string) => void; onClose: () => void}) {
  const [name, setName] = useState("")
  const [body, setBody] = useState("")
  const [tooBig, setTooBig] = useState(false)
  const save = () => {
    if (!name.trim() || !body.trim()) return
    // 64KB inline 上限（后端 @artifact_content_limit 同值，与 ExcalidrawModal 一致）：
    // 超了提示、不保存（文字还在，不丢）。
    if (new Blob([body]).size > 65536) {
      setTooBig(true)
      return
    }
    onSave(name.trim(), body)
    onClose()
  }
  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black/50 p-4 sm:p-6">
      <div className="flex h-full flex-col overflow-hidden rounded-md bg-card shadow-lg">
        <div className="flex items-center justify-between gap-2 border-b border-border px-3 py-2">
          <input
            className={`${inputCls} w-64`}
            placeholder="产物名（如 Gherkin 验收）"
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoFocus
          />
          <div className="flex items-center gap-2">
            {tooBig && <span className="text-xs text-destructive">内容太大(&gt;64KB)，请精简或改用上传文件（文字还在，没丢）</span>}
            <Button type="button" size="sm" disabled={!name.trim() || !body.trim()} onClick={save}>
              保存到节点
            </Button>
            <Button type="button" size="sm" variant="secondary" onClick={onClose}>
              关闭
            </Button>
          </div>
        </div>
        <div className="grid min-h-0 flex-1 grid-cols-1 sm:grid-cols-2">
          <textarea
            className="h-full w-full resize-none border-r border-border bg-background p-3 font-mono text-sm text-foreground outline-none focus:ring-1 focus:ring-ring"
            placeholder={"markdown 内容（存 ezagent 真相源，CI 可读）\nGiven …\nWhen …\nThen …"}
            value={body}
            onChange={(e) => setBody(e.target.value)}
            aria-label="markdown 内容"
          />
          <div className="hidden overflow-y-auto p-3 text-sm text-foreground sm:block" aria-label="预览">
            {body.trim() ? renderMarkdown(body) : <p className="text-muted-foreground">预览（右栏实时渲染）</p>}
          </div>
        </div>
      </div>
    </div>
  )
}

// 最简 markdown 渲染（预览用，零依赖）：#/##/### 标题、- 列表、``` 代码块、
// **粗体**、`行内码`、[文字](链接)。React 转义兜底 XSS——不走 innerHTML。
function renderMarkdown(md: string): ReactNode {
  const out: ReactNode[] = []
  const lines = md.split("\n")
  let i = 0
  let key = 0
  while (i < lines.length) {
    const line = lines[i]
    if (line.trimStart().startsWith("```")) {
      const buf: string[] = []
      i++
      while (i < lines.length && !lines[i].trimStart().startsWith("```")) buf.push(lines[i++])
      i++ // 吃掉闭合 ```
      out.push(<pre key={key++} className="my-1 overflow-x-auto rounded bg-muted p-2 font-mono text-xs">{buf.join("\n")}</pre>)
      continue
    }
    const h = line.match(/^(#{1,3})\s+(.*)$/)
    if (h) {
      const cls = h[1].length === 1 ? "mt-2 text-base font-bold" : h[1].length === 2 ? "mt-2 text-sm font-bold" : "mt-1.5 text-sm font-semibold"
      out.push(<div key={key++} className={cls}>{renderInline(h[2])}</div>)
      i++
      continue
    }
    if (/^\s*[-*]\s+/.test(line)) {
      const items: string[] = []
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*[-*]\s+/, ""))
      out.push(
        <ul key={key++} className="my-1 list-disc pl-5">
          {items.map((it, j) => (<li key={j}>{renderInline(it)}</li>))}
        </ul>,
      )
      continue
    }
    if (line.trim() === "") {
      i++
      continue
    }
    out.push(<p key={key++} className="my-1 whitespace-pre-wrap break-words">{renderInline(line)}</p>)
    i++
  }
  return <>{out}</>
}

// 行内格式：**粗体** / `行内码` / [文字](url)。按最先命中的标记逐段切。
function renderInline(text: string): ReactNode {
  const out: ReactNode[] = []
  let rest = text
  let key = 0
  const pattern = /(\*\*([^*]+)\*\*)|(`([^`]+)`)|(\[([^\]]+)\]\(([^)]+)\))/
  while (rest) {
    const m = rest.match(pattern)
    if (!m || m.index === undefined) {
      out.push(rest)
      break
    }
    if (m.index > 0) out.push(rest.slice(0, m.index))
    if (m[2] !== undefined) out.push(<strong key={key++}>{m[2]}</strong>)
    else if (m[4] !== undefined) out.push(<code key={key++} className="rounded bg-muted px-1 font-mono text-xs">{m[4]}</code>)
    else if (m[6] !== undefined) out.push(<a key={key++} href={m[7]} target="_blank" rel="noreferrer" className="text-primary underline">{m[6]}</a>)
    rest = rest.slice(m.index + m[0].length)
  }
  return <>{out}</>
}

// 校验/操作失败码 → 中文（顶部红横幅用；返回 null 表示不是错误）
const DISPATCH_ERR: Record<string, string> = {
  forbidden: "无权限：节点已被他人认领，只有认领人或版主能改",
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
  no_caller: "缺登录身份，请刷新页面后重试",
  name_required: "名称不能为空",
  invalid_workspace: "工作区无效",
  access_token_required: "缺 Miro access token（在 Plugins → 看板 配置面填）",
  github_repo_missing: "GitHub 仓库未配置（板级 repo 配置已移除）：改用「添加→链接」直接挂 PR 链接",
  bad_pr_number: "PR 号无效：填数字，如 42",
  // 协作模型（2026-07-15）新错误码 → 人话
  root_exists: "已有根节点：本期单根，只能在现有节点下加子",
  // ⑲ 删板
  not_board_owner: "只有板主人（版主）能删除这块板",
  no_session_context: "请先进入一个会话再操作看板",
  has_content_cannot_unclaim: "先清空附件/指标才能取消认领（或直接删除整棵子树）",
  forbidden_mixed_ownership: "子树里有他人认领的节点，不能删",
  identity_read_unavailable: "系统繁忙，请重试",
}
function dispatchError(status?: string | null): string | null {
  if (!status || !status.startsWith("error:")) return null
  const code = status.slice("error:".length)
  return DISPATCH_ERR[code] || `操作失败：${code}`
}

// ㉞：成功不再渲染任何常驻标记（kanban 无「保存」概念，动作即时提交）；
// 只在失败时给出错误提示（KanbanList 用——KanbanDetail 的错误走顶部红横幅）。
function Status({state}: {state: KanbanState}) {
  const err = dispatchError(state.last_dispatch_status)
  if (!err) return null
  return <p className="mt-2 text-xs text-destructive" role="alert">⚠ {err}</p>
}

// Plugin-owned renderer implementation bundled statically into the World shell.
import {useCallback, useEffect, useMemo} from "react"
import {
  Background,
  Controls,
  Handle,
  Position,
  ReactFlow,
  ReactFlowProvider,
  useEdgesState,
  useNodesInitialized,
  useNodesState,
  useReactFlow,
  type Edge,
  type Node as FlowNode,
} from "@xyflow/react"
import dagre from "dagre"
import "@xyflow/react/dist/style.css"

import {Plus} from "lucide-react"

type Node = {
  parent_id: string | null
  title: string
  order: number
  stage: string | null
  owner: string | null
  status: string | null
  artifacts?: {kind?: string; content?: string; ref?: string}[]
  metrics?: unknown[]
}
type Tree = {nodes: Record<string, Node>; root_id: string | null}
type Act = (action: string, args: Record<string, unknown>) => void

const STATUS_ICON: Record<string, string> = {unassigned: "○", claimed: "◔", doing: "◑", done: "●"}

// 9 阶段固定链的中文标签 + 顺序（顺序用于插入校验提示）。
export const STAGES = ["positioning", "metric", "pain", "anchor", "ux", "feature", "issue", "test", "pr"]
export const STAGE_LABEL: Record<string, string> = {
  positioning: "定位",
  metric: "北极星",
  pain: "痛点",
  anchor: "目标用户",
  ux: "体验主张",
  feature: "功能",
  issue: "issue",
  test: "测试",
  pr: "PR",
}

const NODE_W = 210
const NODE_H = 48

// 片4 gate 软门（路A，前端派生）：按节点 stage + artifacts 算"本棒是否过 gate"。
// 纯提示——不拦 status；判据跟 inline content 的 Gherkin/kind 词表对齐。
export type GateVerdict = {verdict: "pass" | "warn" | "none"; reason?: string}
export function gateVerdict(node: {stage?: string | null; status?: string | null; artifacts?: {kind?: string; content?: string; ref?: string}[]}): GateVerdict {
  const arts = (node.artifacts || []) as {kind?: string; content?: string; ref?: string}[]
  const hasKind = (k: string) => arts.some((a) => a.kind === k)
  const hasArtifact = arts.length > 0
  // gate 软门 = 只验"这一棒有没有交付物"(内容无法机读，只能提示有没有产物)。
  // 例外：pr 棒必须先"登记 PR"(挂 pr 产物)才能出站；issue 棒挂 issue 非必须(可选，不报警)。
  switch (node.stage) {
    case "pr":
      return hasKind("pr") ? {verdict: "pass"} : {verdict: "warn", reason: "先登记 PR 才能出站"}
    case "issue":
      return hasArtifact ? {verdict: "pass"} : {verdict: "none"}
    default:
      return hasArtifact ? {verdict: "pass"} : {verdict: "warn", reason: "这一棒还没挂交付物（产物）"}
  }
}

// 自定义节点卡片（react-flow 渲染的每个节点）。点击=选中（属性在侧边栏显示）。
function MmNode({data}: {data: {node: Node; id: string; selected: boolean; onSelect: (id: string) => void; onAddChild: (id: string) => void}}) {
  const {node, id, selected, onSelect, onAddChild} = data
  const owner = node.owner ? node.owner.split("/").pop() : null
  return (
    <div
      onClick={() => onSelect(id)}
      className={`flex items-center gap-1.5 rounded-md border bg-card px-2.5 py-2 text-sm shadow-sm transition ${selected ? "border-primary ring-1 ring-primary" : "border-border"}`}
      style={{width: NODE_W, minHeight: NODE_H}}
    >
      <Handle type="target" position={Position.Left} className="!bg-border" />
      <span className="text-muted-foreground">{STATUS_ICON[node.status || "unassigned"]}</span>
      {node.stage && <span className="rounded bg-muted px-1 text-[10px] text-primary">{STAGE_LABEL[node.stage] || node.stage}</span>}
      <span className="flex-1 truncate font-medium text-foreground" title={node.title}>{node.title}</span>
      {owner && <span className="text-[10px] text-muted-foreground">@{owner}</span>}
      {(() => {
        const gv = gateVerdict(node)
        if (gv.verdict === "warn") return <span title={gv.reason} className="text-amber-500">⚠</span>
        if (gv.verdict === "pass") return <span title="本棒已过 gate" className="text-green-600">✓</span>
        return null
      })()}
      <button
        type="button"
        title="加子节点"
        onPointerDown={(e) => e.stopPropagation()}
        onClick={(e) => {e.stopPropagation(); onAddChild(id)}}
        className="nodrag rounded p-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
      >
        <Plus className="h-3.5 w-3.5" />
      </button>
      <Handle type="source" position={Position.Right} className="!bg-border" />
    </div>
  )
}

const nodeTypes = {mm: MmNode}

function layoutTree(tree: Tree, selectedId: string | null, onSelect: (id: string) => void, onAddChild: (id: string) => void): {nodes: FlowNode[]; edges: Edge[]} {
  const ids = Object.keys(tree.nodes)
  if (ids.length === 0) return {nodes: [], edges: []}
  const g = new dagre.graphlib.Graph()
  g.setGraph({rankdir: "LR", nodesep: 16, ranksep: 70})
  g.setDefaultEdgeLabel(() => ({}))
  for (const id of ids) g.setNode(id, {width: NODE_W, height: NODE_H})
  for (const [id, n] of Object.entries(tree.nodes)) if (n.parent_id && tree.nodes[n.parent_id]) g.setEdge(n.parent_id, id)
  dagre.layout(g)

  const nodes: FlowNode[] = ids.map((id) => {
    const pos = g.node(id)
    return {
      id,
      type: "mm",
      position: {x: pos.x - NODE_W / 2, y: pos.y - NODE_H / 2},
      data: {node: tree.nodes[id], id, selected: id === selectedId, onSelect, onAddChild},
    }
  })
  const edges: Edge[] = Object.entries(tree.nodes)
    .filter(([, n]) => n.parent_id && tree.nodes[n.parent_id!])
    .map(([id, n]) => ({id: `${n.parent_id}-${id}`, source: n.parent_id!, target: id, type: "smoothstep"}))
  return {nodes, edges}
}

type CanvasProps = {
  uri: string
  tree: Tree
  selectedId: string | null
  onSelectNode: (id: string) => void
  onAction: Act
}

// 受控选择：selectedId / onSelectNode 由父组件（KanbanDetail）管，属性面板在侧边栏。
// 外层用 ReactFlowProvider 包，内层 Flow 才能用 useReactFlow 在树变化时重新 fitView。
export function KanbanCanvas(props: CanvasProps) {
  return (
    <ReactFlowProvider>
      <Flow {...props} />
    </ReactFlowProvider>
  )
}

function Flow({uri, tree, selectedId, onSelectNode, onAction}: CanvasProps) {
  const {fitView} = useReactFlow()
  const onAddChild = useCallback((id: string) => {
    const t = window.prompt("子节点标题")
    if (t && t.trim()) onAction("kanban.add_node", {kanban_uri: uri, parent_id: id, title: t.trim()})
  }, [onAction, uri])

  const laid = useMemo(() => layoutTree(tree, selectedId, onSelectNode, onAddChild), [tree, selectedId, onSelectNode, onAddChild])
  const [nodes, setNodes, onNodesChange] = useNodesState(laid.nodes)
  const [edges, setEdges, onEdgesChange] = useEdgesState(laid.edges)
  const nodesInitialized = useNodesInitialized()

  // 树/选中变化 → 重新布局（推给 react-flow）。
  useEffect(() => {
    setNodes(laid.nodes)
    setEdges(laid.edges)
  }, [laid, setNodes, setEdges])

  // fitView 必须等节点被 react-flow **测量好尺寸**(`nodesInitialized`)再跑——否则在节点尺寸
  // 还是 0 时 fit 会把视口算错、节点全跑出可视区(画布空白但节点其实在 DOM 里)。这是之前
  // "建了树画布却空白"的根因。laid 变(加/删节点)→nodesInitialized 先 false 再 true→届时 fit。
  useEffect(() => {
    if (nodesInitialized) fitView({padding: 0.2, maxZoom: 1, duration: 0})
  }, [nodesInitialized, laid, fitView])

  // react-flow 必须有显式尺寸——父级(画布区)现在是固定高 h-[560px]，故 100% 是确定值（非 0）。
  return (
    <div style={{height: "100%", width: "100%"}}>
      <ReactFlow
        nodes={nodes}
        edges={edges}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        onNodeClick={(_, node) => onSelectNode(node.id)}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{padding: 0.2, maxZoom: 1}}
        deleteKeyCode={null}
        minZoom={0.2}
        proOptions={{hideAttribution: true}}
      >
        <Background />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  )
}

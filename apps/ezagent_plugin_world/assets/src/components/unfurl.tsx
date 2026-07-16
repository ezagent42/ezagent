import type React from "react"
import {SquareKanban} from "lucide-react"

import {Button} from "./ui/primitives"

// ㉝ world 通用「链接 unfurl」注册机制（飞书式）——chat 消息渲染的注册式扩展点：
// plugin 声明一个链接模式（pattern）+ 气泡渲染器（render），消息文本命中模式时
// 不显示裸链接、渲成该 plugin 的气泡（点击动作由渲染器自带）。
//
// 机制通用，kanban 是第一个消费者（分享接收链接 → 看板气泡）；其它 plugin 后续
// 加一行 UNFURL_RENDERERS 条目即可复用。与 main.tsx 的 PLUGIN_PAGE_RENDERERS 同一
// 姿势：前端注册表 + 显式 import（Vite 静态打包），零动态加载。
//
// ㉙「分享到会话」发出的消息与 ㉝ 手工粘贴的链接走同一条渲染路——同一个气泡组件。

export type UnfurlContext = {
  // 当前会话 URI（渲染器可用作点击动作的会话上下文）
  sessionUri: string
  // 该消息是否是查看者自己发的（气泡配色可能要适配）
  mine: boolean
}

export type UnfurlRenderer = {
  id: string
  // 消息文本中匹配链接的模式（第一个命中即选中该渲染器）
  pattern: RegExp
  // rest = 去掉链接后的剩余文本（作气泡标题/说明；可为空串）
  render: (url: string, rest: string, ctx: UnfurlContext) => React.ReactElement
}

export type UnfurlMatch = {renderer: UnfurlRenderer; url: string; rest: string}

// kanban 分享气泡（㉙/㉝ 共用）：标题 + 「加入我的看板」按钮。
// 点击 = 跳接收落点（债③ 后 receive 仍是 HTTP GET：verify token → plugin
// receive_shared_board 挂载 → 302 回落点会话页），挂载后回来。
export function KanbanShareBubble({url, label}: {url: string; label?: string | null}) {
  return (
    <div
      className="mt-1 flex max-w-[320px] flex-col gap-2 rounded-[10px] border border-border bg-card p-3 text-card-foreground shadow-sm"
      data-world-unfurl="kanban-share"
    >
      <div className="flex items-center gap-2">
        <SquareKanban aria-hidden="true" className="h-4 w-4 shrink-0 text-primary" />
        <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-foreground" title={label || undefined}>
          {label || "看板分享"}
        </span>
      </div>
      <p className="m-0 text-xs text-muted-foreground">点击加入这块看板（按你的身份决定可编辑/只读）。</p>
      <div>
        <Button type="button" size="sm" onClick={() => window.location.assign(url)}>
          加入我的看板
        </Button>
      </div>
    </div>
  )
}

// kanban 分享接收链接：world `KanbanActions.build_share_link` 生成的
// `/socialware/kanban/receive?token=...`（相对路径），或经外部粘贴的绝对 URL。
const KANBAN_RECEIVE_PATTERN = /(?:https?:\/\/[^\s"'）)]*)?\/socialware\/kanban\/receive\?token=[A-Za-z0-9._~%-]+/

export const UNFURL_RENDERERS: UnfurlRenderer[] = [
  {
    id: "kanban-share",
    pattern: KANBAN_RECEIVE_PATTERN,
    render: (url, rest) => <KanbanShareBubble url={url} label={rest || null} />,
  },
]

// 消息文本 → 第一个命中的 unfurl 渲染器。rest = 去掉链接本身后的剩余文本
// （trim 过；「【看板分享】看板「x」」这类说明语留作气泡标题）。
export function matchUnfurl(text: string): UnfurlMatch | null {
  for (const renderer of UNFURL_RENDERERS) {
    const m = text.match(renderer.pattern)
    if (m && m.index !== undefined) {
      const rest = (text.slice(0, m.index) + text.slice(m.index + m[0].length)).trim()
      return {renderer, url: m[0], rest}
    }
  }
  return null
}

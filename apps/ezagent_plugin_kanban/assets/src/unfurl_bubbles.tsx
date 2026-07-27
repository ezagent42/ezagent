import {SquareKanban} from "lucide-react"

import type {UnfurlBubbleProps} from "../../../ezagent_plugin_world/assets/src/components/unfurl"
import {Button} from "../../../ezagent_plugin_world/assets/src/components/ui/primitives"

// kanban 的链接 unfurl 气泡（#1569 world 通用 unfurl 机制的 kanban 侧消费者）：
// 链接模式（pattern）在 `application.ex` `pages/0` 的 `:unfurl` 字段声明（正则
// source 字符串），`mix world.renderers.manifest` 生成静态注册表把它们和本文件的
// 组件接起来；world 的 chat 渲染命中模式时渲成这里的气泡，点击动作走 `ctx.dispatch`
// （world:dispatch，in-app、零整屏跳转）。
//
// ㉙「分享到会话」发出的消息与手工粘贴的接收链接走同一条渲染路——同一个气泡组件。

// ㊵ 人本位：接收链接里的 token（`?token=...`）。in-app 点击把 token 交给
// world:dispatch `kanban.receive_shared`（后端 verify + 只读钥匙发给点击者本人 +
// 原地切看板 tab，零整屏跳转）；解析不出 token / 无 dispatch 通道（理论上不发生）
// 时回退整屏跳 HTTP 深链入口。
function tokenOf(url: string): string | null {
  const m = url.match(/[?&]token=([A-Za-z0-9._~%-]+)/)
  return m ? m[1] : null
}

// kanban 分享气泡（㉙/㉝ 共用）：标题 + 「加入我的看板」按钮。
// ㊵ 点击 = world:dispatch kanban.receive_shared（只读钥匙发给点击者**本人**，
// 板出现在自己的看板 tab，不发生 session 跳转）。
export function KanbanShareBubble({url, rest, ctx}: UnfurlBubbleProps) {
  const label = rest || null
  const receive = () => {
    const token = tokenOf(url)
    if (ctx.dispatch && token) ctx.dispatch("kanban.receive_shared", {token})
    else window.location.assign(url)
  }
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
      <p className="m-0 text-xs text-muted-foreground">点击领取这块看板的只读钥匙（发给你本人），在看板标签查看。</p>
      <div>
        <Button type="button" size="sm" onClick={receive}>
          加入我的看板
        </Button>
      </div>
    </div>
  )
}

function queryParam(url: string, key: string): string | null {
  const m = url.match(new RegExp(`[?&]${key}=([A-Za-z0-9._~%-]+)`))
  return m ? decodeURIComponent(m[1]) : null
}

// 规则8 申请编辑气泡：`kanban.request_edit` 物化的申请消息带
// `/plugins/kanban/request-edit?board=<enc>&grantee=<enc>` 伪链接——渲成
// 申请人/看板信息 + 「批准编辑」按钮（仅板主人点了有效，非主人后端拒
// `:not_board_owner`——授权在后端，按钮只是入口；点批准 dispatch
// kanban.approve_edit，read→operate 升级）。
export function KanbanRequestEditBubble({url, rest, ctx}: UnfurlBubbleProps) {
  const label = rest || null
  const board = queryParam(url, "board")
  const grantee = queryParam(url, "grantee")
  const approve = () => {
    if (ctx.dispatch && board && grantee) ctx.dispatch("kanban.approve_edit", {kanban_uri: board, grantee})
  }
  return (
    <div
      className="mt-1 flex max-w-[320px] flex-col gap-2 rounded-[10px] border border-border bg-card p-3 text-card-foreground shadow-sm"
      data-world-unfurl="kanban-request-edit"
    >
      <div className="flex items-center gap-2">
        <SquareKanban aria-hidden="true" className="h-4 w-4 shrink-0 text-primary" />
        <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-foreground" title={label || undefined}>
          {label || "申请编辑看板"}
        </span>
      </div>
      <p className="m-0 text-xs text-muted-foreground">
        {grantee ? `${grantee.split("/").pop()} 申请编辑权限（只读 → 可编辑）。` : "申请编辑权限（只读 → 可编辑）。"}
        板主人点「批准」后生效。
      </p>
      <div>
        <Button type="button" size="sm" onClick={approve} disabled={!ctx.dispatch || !board || !grantee}>
          批准编辑
        </Button>
      </div>
    </div>
  )
}

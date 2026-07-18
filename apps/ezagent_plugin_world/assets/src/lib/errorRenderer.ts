import {ERROR_CODES, UNKNOWN_ERROR, type ErrorCategory, type ErrorCode} from "./errorCodes"
import {DISPATCH_ERROR_PREFIX, matchDispatchError} from "./errorMatcher"

export type ErrorLayer = 1 | 2 | 3

export type RenderedError = {
  code: string
  category: ErrorCategory
  what: string
  impact: string
  layer: ErrorLayer
  // 具体错误内容(从 last_dispatch_status 的 raw reason 清理而来),
  // 给用户/支持人员定位用;注册表文案只覆盖通用描述。
  detail?: string
  primaryAction?: {
    label: string
    href?: string
    action?: string
    args?: Record<string, unknown>
  }
  secondaryAction?: {
    label: string
    action: string
    args?: Record<string, unknown>
  }
}

export type CurrentUser = {
  entity_uri?: string | null
  workspace_uri?: string | null
  is_system_member?: boolean
}

// 根据当前用户和错误码决定渲染层级与行动入口。
// Layer 1：用户有 fix_path 权限，直接给修复链接。
// Layer 2：用户无权限，但有 fix_owner，给「找谁修」+ 提醒按钮。
// Layer 3：fix_owner 为空，仅展示 what/impact，走系统自动登记。
export function renderError(code: string, user: CurrentUser): RenderedError {
  const entry = ERROR_CODES.find((e) => e.code === code) || UNKNOWN_ERROR
  const canFix = canFixPath(entry, user)

  if (entry.fixPath && canFix) {
    return {
      code: entry.code,
      category: entry.category,
      what: entry.what,
      impact: entry.impact,
      layer: 1,
      primaryAction: {
        label: "前往修复",
        href: entry.fixPath,
      },
    }
  }

  if (entry.fixOwner) {
    return {
      code: entry.code,
      category: entry.category,
      what: entry.what,
      impact: entry.impact,
      layer: 2,
      secondaryAction: {
        label: "提醒可修复人",
        action: "error.notify_admin",
        args: {code: entry.code, workspace_uri: user.workspace_uri},
      },
    }
  }

  return {
    code: entry.code,
    category: entry.category,
    what: entry.what,
    impact: entry.impact,
    layer: 3,
  }
}

function canFixPath(_entry: ErrorCode, user: CurrentUser): boolean {
  // 最小可行：system member 或 workspace founder 可修复。
  // 后续后端通过 caller caps 精确判断时，替换为传入的 capability 检查。
  return user.is_system_member === true
}

// 把 `last_dispatch_status` 统一翻译成卡片（或 null）。初始 mount、
// `world:state` 推送和 WorldRenderer.updated() 的 data-last-dispatch 同步
// 共用这一条规则：只有 "error:" 前缀的状态才渲染卡片；
// "ok" / "idle" / null 一律清卡（成功 dispatch 覆盖旧的失败态）。
export function errorCardForStatus(status: string | null | undefined, user: CurrentUser): RenderedError | null {
  if (!status || !status.startsWith(DISPATCH_ERROR_PREFIX)) return null
  const reason = status.slice(DISPATCH_ERROR_PREFIX.length)
  const match = matchDispatchError(status)
  const detail = errorDetail(reason)
  return {...renderError(match.code, user), ...(detail ? {detail} : {})}
}

// 把后端 raw reason 清理成可展示的具体错误内容:去掉 Elixir inspect 的
// 包装(最外层 {…}、atom 前缀冒号、字符串引号),保留 reason 本体。
// 例:`{:already_exists, "entity://system/agent/x"}` → `already_exists, entity://system/agent/x`
export function errorDetail(reason: string): string {
  let detail = reason.trim()
  if (detail.startsWith("{") && detail.endsWith("}")) detail = detail.slice(1, -1)
  if (detail.startsWith(":")) detail = detail.slice(1)
  return detail.replaceAll('"', "").trim()
}

// 三色语义(2026-07-18 产品决定):
//   红 danger — 执行失败类:凭据/权限/未识别错误(如 agent 创建失败)
//   黄 warning — 状态/资源类:agent 未就绪、额度不足
//   蓝 info   — 输入校验类:参数不合法等可修正输入
export function categoryTone(category: ErrorCategory): "danger" | "warning" | "info" {
  switch (category) {
    case "credential":
    case "permission":
    case "unknown":
      return "danger"
    case "lifecycle":
    case "resource":
      return "warning"
    case "validation":
    default:
      return "info"
  }
}

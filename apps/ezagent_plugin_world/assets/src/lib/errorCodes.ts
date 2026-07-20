// G5 通用可配置错误机制 —— 前端错误码注册表（beta 第一批）
// 与 SOP docs/plans/2026-07-17-error-mechanism-sop.md §2/§6 对齐
// 当前为前端最小可行实现：直接解析后端 `last_dispatch_status` 字符串里的 reason。

export type ErrorCategory =
  | "credential"
  | "permission"
  | "lifecycle"
  | "validation"
  | "resource"
  | "unknown"

export type ErrorCode = {
  code: string
  category: ErrorCategory
  what: string
  impact: string
  fixPath?: string
  fixOwner?: string
}

export type ErrorMatch = {
  code: string
  category: ErrorCategory
  what: string
  impact: string
  fixPath?: string
  fixOwner?: string
}

// beta 第一批 7 条错误码
export const ERROR_CODES: ErrorCode[] = [
  {
    code: "agent_credential_missing",
    category: "credential",
    what: "Agent 未配置凭证",
    impact: "无法调用 AI 模型，你的消息暂时无法得到回复",
    fixPath: "/identities/agents",
    fixOwner: "workspace_founder",
  },
  {
    code: "agent_not_ready",
    category: "lifecycle",
    what: "Agent 尚未就绪",
    impact: "暂时无法处理你的请求，请稍后再试",
  },
  {
    code: "action_unauthorized",
    category: "permission",
    what: "你没有权限执行此操作",
    impact: "如需访问，请联系 workspace founder",
    fixOwner: "workspace_founder",
  },
  {
    code: "cross_workspace_denied",
    category: "permission",
    what: "跨 workspace 访问被拒绝",
    impact: "无法在当前 workspace 执行该操作",
    fixOwner: "workspace_founder",
  },
  {
    code: "invalid_args",
    category: "validation",
    what: "输入内容不符合规则",
    impact: "无法完成操作，请修改后重试",
  },
  {
    code: "member_not_registered",
    category: "validation",
    what: "成员未注册",
    impact: "无法将其加入会话，请先完成注册",
  },
  {
    code: "quota_exhausted",
    category: "resource",
    what: "Workspace 的 API 调用配额已用完",
    impact: "Agent 暂时无法回复消息",
    fixOwner: "workspace_founder",
  },
]

// 未知错误兜底
export const UNKNOWN_ERROR: ErrorCode = {
  code: "unknown",
  category: "unknown",
  what: "Agent 执行时遇到错误",
  impact: "无法完成你的请求",
}

import {ERROR_CODES, UNKNOWN_ERROR, type ErrorCategory, type ErrorMatch} from "./errorCodes"

// 将后端 dispatch reason 映射为可展示的错误码。
// 最小可行阶段复用 `last_dispatch_status` 字符串，格式为 "error:<reason>"；
// 后续后端可直接推送结构化错误码，前端只需扩展 matchReason 即可。

export const DISPATCH_ERROR_PREFIX = "error:"

export function matchDispatchError(status: string | null | undefined): ErrorMatch {
  if (!status || !status.startsWith(DISPATCH_ERROR_PREFIX)) {
    return {...UNKNOWN_ERROR}
  }

  const reason = status.slice(DISPATCH_ERROR_PREFIX.length)
  return matchReason(reason)
}

export function matchReason(reason: string): ErrorMatch {
  const matched = ERROR_CODES.find((entry) => {
    // 1. 精确匹配 code 本身（后端已返回 code）
    if (entry.code === reason) return true

    // 2. 匹配 reason 与 code 的命名映射
    return codeFromReason(reason) === entry.code
  })

  return matched ? {...matched} : {...UNKNOWN_ERROR}
}

// 将后端裸 reason atom 字符串映射到 SOP 定义的 code。
// 这是临时兼容层，待后端 ErrorMatcher 落地后可删除。
function codeFromReason(reason: string): string | null {
  if (reason === "no_api_key") return "agent_credential_missing"
  if (reason === "not_ready") return "agent_not_ready"
  if (reason === "unauthorized") return "action_unauthorized"
  if (reason === "cross_workspace_denied") return "cross_workspace_denied"
  if (reason === "bad_args" || reason.startsWith("bad_args")) return "invalid_args"
  if (reason === "invalid_args") return "invalid_args"
  if (reason === "binding_fields_required") return "invalid_args"
  if (reason === "invalid_entity_uri") return "invalid_args"
  if (reason === "open_id_required") return "invalid_args"
  if (reason.startsWith("member_not_registered")) return "member_not_registered"
  if (reason === "quota_exhausted") return "quota_exhausted"
  return null
}

export type {ErrorCategory, ErrorMatch}
export {UNKNOWN_ERROR}

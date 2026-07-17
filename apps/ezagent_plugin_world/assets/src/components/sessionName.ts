export const SESSION_NAME_HINT = "可包含中文、英文字母、数字、下划线和连字符，2-30 个字符。"

const SESSION_NAME_PATTERN = /^[\p{L}\p{N}_-]+$/u

export function normalizeSessionName(value: string): string {
  return value.trim().replace(/\s+/gu, "-")
}

export function sessionNameError(value: string): string | null {
  const normalized = normalizeSessionName(value)
  if (!normalized) return "请输入会话名称"

  const length = [...normalized].length
  if (length < 2) return "名称至少需要 2 个字符"
  if (length > 30) return "名称不能超过 30 个字符"

  if (!SESSION_NAME_PATTERN.test(normalized)) {
    return "名称只能包含中文、英文字母、数字、下划线和连字符"
  }

  return null
}

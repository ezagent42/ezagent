import {describe, expect, it} from "vitest"
import {matchDispatchError, matchReason} from "./errorMatcher"
import {ERROR_CODES, UNKNOWN_ERROR} from "./errorCodes"

describe("matchDispatchError", () => {
  it("returns unknown for null/undefined/non-error status", () => {
    expect(matchDispatchError(null).code).toBe("unknown")
    expect(matchDispatchError(undefined).code).toBe("unknown")
    expect(matchDispatchError("ok").code).toBe("unknown")
  })

  it("matches registered error codes directly", () => {
    const matched = matchDispatchError("error:agent_credential_missing")
    expect(matched.code).toBe("agent_credential_missing")
    expect(matched.category).toBe("credential")
    expect(matched.what).toBe("Agent 未配置凭证")
  })

  it("maps backend atom reasons to registered codes", () => {
    expect(matchDispatchError("error:no_api_key").code).toBe("agent_credential_missing")
    expect(matchDispatchError("error:unauthorized").code).toBe("action_unauthorized")
    expect(matchDispatchError("error:cross_workspace_denied").code).toBe("cross_workspace_denied")
    expect(matchDispatchError("error:not_ready").code).toBe("agent_not_ready")
    expect(matchDispatchError("error:bad_args").code).toBe("invalid_args")
    expect(matchDispatchError("error:member_not_registered").code).toBe("member_not_registered")
  })

  it("falls back to unknown for unrecognized reasons", () => {
    const matched = matchDispatchError("error:something_else")
    expect(matched.code).toBe("unknown")
    expect(matched.category).toBe("unknown")
  })
})

describe("matchReason", () => {
  it("covers all beta error codes", () => {
    for (const entry of ERROR_CODES) {
      expect(matchReason(entry.code).code).toBe(entry.code)
    }
  })

  it("preserves message fields on match", () => {
    const matched = matchReason("quota_exhausted")
    expect(matched.impact).toBe("Agent 暂时无法回复消息")
    expect(matched.fixOwner).toBe("workspace_founder")
  })

  it("does not claim data was unchanged when binding rollback fails", () => {
    const matched = matchReason("binding_rollback_failed")
    expect(matched.code).toBe("binding_rollback_failed")
    expect(matched.impact).toContain("可能")
    expect(matched.impact).not.toContain("数据未变更")
  })

  it("returns unknown fields for unrecognized reason", () => {
    const matched = matchReason("totally_unknown_reason")
    expect(matched.code).toBe(UNKNOWN_ERROR.code)
    expect(matched.what).toBe(UNKNOWN_ERROR.what)
  })
})

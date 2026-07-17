import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {AdminSurface, smtpTestResultMessage, type AdminState} from "./Admin"

function renderSettings(settings: NonNullable<AdminState["settings"]>) {
  return renderToStaticMarkup(<AdminSurface state={{component: "settings", settings}} />)
}

describe("admin settings visibility", () => {
  it("shows registration controls next to SMTP settings for the administrator", () => {
    const html = renderSettings({
      can_manage_registration: true,
      registration_open: false,
      registration_require_invite: true,
      registration_requests: [],
      smtp: {},
    })

    expect(html).toContain("data-world-registration-settings")
    expect(html).toContain('id="world-registration-settings-form"')
    expect(html).toContain('id="world-smtp-form"')
  })

  it("hides registration controls from non-admin users without hiding SMTP settings", () => {
    const html = renderSettings({can_manage_registration: false, smtp: {}})

    expect(html).not.toContain("data-world-registration-settings")
    expect(html).not.toContain('id="world-registration-settings-form"')
    expect(html).toContain('id="world-smtp-form"')
  })
})

describe("SMTP result presentation", () => {
  it("maps stable result codes to Chinese actionable messages", () => {
    expect(smtpTestResultMessage("ok:delivered")).toContain("已发送")
    expect(smtpTestResultMessage("error:recipient_required")).toContain("填写")
    expect(smtpTestResultMessage("error:smtp_not_configured")).toContain("先保存")
    expect(smtpTestResultMessage("error:smtp_send_failed")).toContain("检查 SMTP 配置")
  })

  it("never exposes an unknown technical code", () => {
    expect(smtpTestResultMessage("error:some_internal_atom")).not.toContain("some_internal_atom")
  })
})

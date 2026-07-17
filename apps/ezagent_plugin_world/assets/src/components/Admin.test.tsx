import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {AdminSurface, type AdminState} from "./Admin"

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

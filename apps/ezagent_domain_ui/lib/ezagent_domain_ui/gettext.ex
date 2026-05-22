defmodule EzagentDomainUi.Gettext do
  @moduledoc """
  Gettext backend for the Tier-2 shared UI component library.

  i18n (Allen 2026-05-22) — the `ezagent_domain_ui` shell + primitive
  components (`ide_shell`, `workspace_shell`, `admin_shell`, ...) render
  a small amount of user-facing chrome (nav labels, tooltips, the
  search placeholder, "Sign out", ...). Wrapping those in `gettext/1`
  requires a backend.

  ## Why a domain_ui-owned backend (3-tier note)

  A Tier-2 `ezagent_domain_ui` component MUST NOT depend on the Tier-3
  `EzagentWeb.Gettext`. But a Gettext *backend* is just a per-OTP-app
  translation namespace built on the standalone `:gettext` Hex library
  — it is NOT a dependency on `ezagent_web`. Each OTP app owning its
  own backend + `priv/gettext` tree is the standard Phoenix pattern for
  a shared component library. domain_ui stays self-sufficient for
  translation and no tier boundary is crossed.

  The runtime locale (`Gettext.put_locale/2`) is process-dictionary
  state. `EzagentWeb.Plugs.Locale` / `EzagentWeb.LiveAuth` set the
  locale once per request/LV-process; this backend reads the same
  process locale, so a single `?locale=zh_CN` switch translates both
  the `ezagent_web` strings and these domain_ui strings consistently.

  Translations live in `apps/ezagent_domain_ui/priv/gettext`.
  """
  use Gettext.Backend, otp_app: :ezagent_domain_ui
end

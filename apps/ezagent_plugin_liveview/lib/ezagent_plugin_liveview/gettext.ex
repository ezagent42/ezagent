defmodule EzagentPluginLiveview.Gettext do
  @moduledoc """
  Gettext backend for the admin web-UI plugin.

  i18n (Allen 2026-05-22) — every LiveView + plugin component in
  `ezagent_plugin_liveview` wraps its user-facing strings in
  `gettext/1` against THIS backend.

  ## Why a plugin-owned backend (not `EzagentWeb.Gettext`)

  An earlier iteration of these LVs `use`d `EzagentWeb.Gettext` as a
  runtime module reference. That works at runtime, but `mix
  gettext.extract` is a COMPILE-TIME macro pass: on a clean umbrella
  build the plugin compiles BEFORE `ezagent_web`, so the extractor
  cannot resolve `EzagentWeb.Gettext.__gettext__/1` and the build
  fails. A plugin-owned backend (the standard Phoenix per-OTP-app
  pattern) makes `mix gettext.extract` self-contained — no cross-app
  compile-order hazard.

  `:gettext` is a standalone Hex library; depending on it does NOT
  couple the plugin to `ezagent_web`.

  ## Locale propagation

  The runtime locale (`Gettext.put_locale/2`) is per-backend,
  per-process dictionary state. `EzagentWeb.Plugs.Locale` /
  `EzagentWeb.LiveAuth` set the locale for `EzagentPluginLiveview.Gettext`
  alongside `EzagentWeb.Gettext` + `EzagentDomainUi.Gettext`, so one
  `?locale=zh_CN` switch translates every tier consistently.

  Translations live in `apps/ezagent_plugin_liveview/priv/gettext`.
  """
  use Gettext.Backend, otp_app: :ezagent_plugin_liveview
end

defmodule EzagentPluginHello.Gettext do
  @moduledoc """
  Gettext backend for the hello plugin's user-facing builder narration.

  i18n (#91, Allen 2026-06-23) — `EzagentPluginHello.Generator` narrates a
  page-generation turn back to the operator ("understanding your request…",
  "structure generated: …", "render failed: …"). Those strings are
  user-facing copy, so they go through `gettext/1,2` instead of being baked
  in as literals. The anti-CJK arch gate
  (`EzagentCore.Architecture.CjkLiteralGate`) enforces this: no Han-character
  string literals may live in `apps/ezagent_plugin_hello/lib`; the Chinese
  copy lives in `priv/gettext/zh_CN/LC_MESSAGES/default.po`.

  ## Why a plugin-owned backend (3-tier + plugin-isolation note)

  A Gettext *backend* is a per-OTP-app translation namespace built on the
  standalone `:gettext` Hex library — it is NOT a dependency on any tier.
  The hello plugin owning its own backend + `priv/gettext` tree is the
  standard Phoenix pattern for a self-contained component and keeps the
  plugin's copy out of `ezagent_domain_ui`'s shared-chrome namespace
  (North Star: plugin isolation — a plugin must not dump its strings into a
  domain's translation namespace).

  ## Locale

  The narration runs in a `Generator` Task process with no per-request
  `Locale` plug, so `Generator.generate/2` pins the turn's locale with
  `Gettext.put_locale(__MODULE__, "zh_CN")`. The configured default
  (`config/config.exs`) is also `zh_CN`, so the copy renders Chinese
  regardless of caller context — preserving the pre-i18n behaviour. Adding
  an `en` translation + a runtime locale switch is a future, additive step.
  """
  use Gettext.Backend, otp_app: :ezagent_plugin_hello
end

defmodule EzagentWeb.AuthBoundaryLayout do
  @moduledoc """
  Shared HTML chrome for the auth-boundary pages (`/login`,
  `/login/credentials`, `/register/complete`).

  Both controllers (`SessionController`, `RegistrationController`) use
  `Phoenix.Controller, formats: [:html], layouts: []` and deliberately
  skip the LV root layout — the auth-boundary path must work even if
  the LiveView WebSocket cannot connect (Phase 4 Spec 05 §A.2.3). That
  is why they each render a raw heredoc HTML string instead of HEEx.

  Pre-PR-E (SPEC v2 §G7), the login page carried ~270 LOC of inline
  CSS (full Geist font + design tokens + dark mode + mobile-visible
  flash) and the registration page carried ~25 LOC of stripped legacy
  CSS — so the two looked dramatically different. This helper extracts
  the chrome verbatim from `SessionController` so both pages share the
  exact same shell.

  This module returns raw HTML strings (not HEEx / `Phoenix.Component`)
  so callers can keep using their `String.replace/3` placeholder
  substitution. Whether to introduce a HEEx version is a separate
  refactor — out of scope for PR-E.

  ## Usage

      html =
        AuthBoundaryLayout.head_html(gettext("Sign in")) <>
        AuthBoundaryLayout.body_open() <>
        AuthBoundaryLayout.card_open() <>
          inner_html <>
        AuthBoundaryLayout.card_close() <>
        AuthBoundaryLayout.body_close()

  The flash bubble for surfacing `Phoenix.Flash` on the auth boundary
  is available via `flash_html/1` — see `SessionController`'s
  `render_login_page/2` for the canonical call site.
  """

  @doc """
  Opens the `<body>` element. Pair with `body_close/0`.
  """
  @spec body_open() :: String.t()
  def body_open, do: "<body>\n"

  @doc """
  Closes the `<body>` + `<html>` elements. Pair with `body_open/0`.
  """
  @spec body_close() :: String.t()
  def body_close, do: "</body>\n</html>\n"

  @doc """
  Opens the centered card. Pair with `card_close/0`.
  """
  @spec card_open() :: String.t()
  def card_open, do: ~s(<div class="card">\n)

  @doc """
  Closes the centered card. Pair with `card_open/0`.
  """
  @spec card_close() :: String.t()
  def card_close, do: "</div>\n"

  @doc """
  Renders the mobile-visible flash bubble for the auth boundary.

  Reads `conn.assigns[:flash]` (Phoenix.Flash convention) and returns
  styled `<div class="flash-mobile flash-{kind}">` blocks for any
  `:info` / `:error` entries. Returns `""` when there are no flashes.

  Pre-PR-E this lived inline in `SessionController.build_flash_html/1`;
  moved here so `RegistrationController` (and any future auth-boundary
  page) gets the same mobile-visible flash UX for free.
  """
  @spec flash_html(Plug.Conn.t()) :: String.t()
  def flash_html(%Plug.Conn{} = conn) do
    flash = conn.assigns[:flash] || %{}
    info = Map.get(flash, "info")
    error = Map.get(flash, "error")

    [
      flash_bubble("info", info, "ℹ"),
      flash_bubble("error", error, "⚠")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
  end

  defp flash_bubble(_kind, nil, _icon), do: ""
  defp flash_bubble(_kind, "", _icon), do: ""

  defp flash_bubble(kind, msg, icon) when is_binary(msg) do
    ~s(<div class="flash-mobile flash-#{kind}" role="alert"><span class="flash-icon">#{icon}</span><span class="flash-text">) <>
      esc(msg) <> "</span></div>"
  end

  # html_escape across Plug versions returns either an iodata or a
  # binary; normalize to binary so callers' `String.replace/3` accepts it.
  defp esc(text) do
    case Plug.HTML.html_escape(text) do
      bin when is_binary(bin) -> bin
      iodata -> IO.iodata_to_binary(iodata)
    end
  end

  # The chrome — extracted verbatim from
  # `SessionController` (Phase 8c PR-D head + Allen 2026-05-24 flash
  # bubble). Editing styles here updates BOTH login and registration.
  @head_template ~S"""
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <title>{{TITLE}}</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
    <style>
      :root {
        --font-sans: 'Geist', ui-sans-serif, system-ui, -apple-system, sans-serif;
        --font-mono: 'JetBrains Mono', ui-monospace, Menlo, monospace;
        --ink: #0a0a0a;
        --ink-dim: #525252;
        --line: #e5e5e5;
        --accent: #1f883d;
        --accent-faint: #e6f4ea;
        --bg-page: #fafafa;
        --bg-card: #ffffff;
        --bg-input: #ffffff;
        --bg-code: #f4f4f5;
        --error-fg: #b91c1c;
        --error-bg: #fef2f2;
        --error-line: #fecaca;
        --info-fg: #047857;
        --info-bg: #ecfdf5;
        --info-line: #a7f3d0;
        --btn-fg: #ffffff;
      }
      /* Phase 8c PR-D — explicit theme + system-pref fallback. The
         login page renders before the LV WS, so we honor both
         data-theme=dark (set by the toggle JS) and the prefers-color-scheme. */
      :root[data-theme="dark"] {
        --ink: #fafafa;
        --ink-dim: #a3a3a3;
        --line: #27272a;
        --accent: #4ade80;
        --accent-faint: #052e16;
        --bg-page: #09090b;
        --bg-card: #18181b;
        --bg-input: #18181b;
        --bg-code: #27272a;
        --error-fg: #fca5a5;
        --error-bg: #450a0a;
        --error-line: #7f1d1d;
        --info-fg: #6ee7b7;
        --info-bg: #022c1e;
        --info-line: #064e3b;
        --btn-fg: #18181b;
      }
      @media (prefers-color-scheme: dark) {
        :root:not([data-theme="light"]) {
          --ink: #fafafa;
          --ink-dim: #a3a3a3;
          --line: #27272a;
          --accent: #4ade80;
          --accent-faint: #052e16;
          --bg-page: #09090b;
          --bg-card: #18181b;
          --bg-input: #18181b;
          --bg-code: #27272a;
          --error-fg: #fca5a5;
          --error-bg: #450a0a;
          --error-line: #7f1d1d;
          --info-fg: #6ee7b7;
          --info-bg: #022c1e;
          --info-line: #064e3b;
          --btn-fg: #18181b;
        }
      }
      * { box-sizing: border-box; }
      html, body { height: 100%; }
      body {
        margin: 0;
        font-family: var(--font-sans);
        color: var(--ink);
        background:
          radial-gradient(circle at 0% 0%, rgba(31,136,61,0.04), transparent 40%),
          radial-gradient(circle at 100% 100%, rgba(10,10,10,0.03), transparent 40%),
          var(--bg-page);
        display: grid;
        place-items: center;
        padding: 24px;
      }
      .card {
        width: 100%;
        max-width: 380px;
        background: var(--bg-card);
        border: 1px solid var(--line);
        border-radius: 12px;
        padding: 32px 28px;
        box-shadow: 0 1px 0 rgba(0,0,0,0.02), 0 8px 24px -12px rgba(0,0,0,0.06);
      }
      .brand {
        font-family: var(--font-mono);
        font-size: 12px;
        letter-spacing: 0.12em;
        color: var(--ink-dim);
        text-transform: uppercase;
        margin: 0 0 4px;
      }
      h1 { font-size: 22px; font-weight: 600; margin: 0 0 24px; letter-spacing: -0.01em; }
      form { display: flex; flex-direction: column; gap: 10px; }
      label { font-size: 12px; color: var(--ink-dim); font-weight: 500; }
      input {
        padding: 10px 12px;
        border: 1px solid var(--line);
        border-radius: 8px;
        font-size: 14px;
        font-family: var(--font-mono);
        background: var(--bg-input);
        color: var(--ink);
        transition: border-color 120ms ease;
      }
      input:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-faint); }
      button {
        margin-top: 4px;
        padding: 10px 14px;
        background: var(--ink);
        color: var(--btn-fg);
        border: none;
        border-radius: 8px;
        font-size: 14px;
        font-weight: 500;
        font-family: var(--font-sans);
        cursor: pointer;
        transition: opacity 120ms ease;
      }
      button:hover { opacity: 0.85; }
      button.secondary {
        background: var(--bg-input);
        color: var(--ink);
        border: 1px solid var(--line);
      }
      button.secondary:disabled {
        cursor: not-allowed;
        opacity: 0.5;
      }
      .error {
        color: var(--error-fg);
        font-size: 13px;
        padding: 10px 12px;
        background: var(--error-bg);
        border: 1px solid var(--error-line);
        border-radius: 8px;
        margin-bottom: 12px;
      }
      .info {
        color: var(--info-fg);
        font-size: 13px;
        padding: 10px 12px;
        background: var(--info-bg);
        border: 1px solid var(--info-line);
        border-radius: 8px;
        margin-bottom: 12px;
      }
      /* Allen 2026-05-24 — mobile-visible flash bubble for the auth
         boundary. Surfaces Phoenix.Flash via AuthBoundaryLayout.flash_html/1.
         Larger font + icon + heavier border so a thumb-scroll user
         can't miss it. */
      .flash-mobile {
        display: flex;
        align-items: flex-start;
        gap: 10px;
        padding: 14px 16px;
        margin-bottom: 16px;
        border-radius: 10px;
        border-width: 2px;
        border-style: solid;
        font-size: 15px;
        line-height: 1.4;
        font-weight: 500;
        box-shadow: 0 2px 4px rgba(0,0,0,0.04);
      }
      .flash-mobile .flash-icon {
        font-size: 18px;
        line-height: 1;
        flex-shrink: 0;
      }
      .flash-mobile .flash-text {
        flex: 1;
      }
      .flash-error {
        color: var(--error-fg);
        background: var(--error-bg);
        border-color: var(--error-line);
      }
      .flash-info {
        color: var(--info-fg);
        background: var(--info-bg);
        border-color: var(--info-line);
      }
      .divider {
        display: flex;
        align-items: center;
        gap: 10px;
        margin: 18px 0;
        color: var(--ink-dim);
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.1em;
      }
      .divider::before, .divider::after {
        content: '';
        flex: 1;
        height: 1px;
        background: var(--line);
      }
      .section-label {
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: var(--ink-dim);
        margin: 0 0 8px;
        font-weight: 500;
      }
      .disabled-notice {
        font-size: 12px;
        color: var(--ink-dim);
        padding: 10px 12px;
        background: var(--bg-code);
        border: 1px dashed var(--line);
        border-radius: 8px;
      }
      .hint { color: var(--ink-dim); font-size: 12px; margin: 18px 0 0; line-height: 1.55; }
      code { font-family: var(--font-mono); font-size: 11px; background: var(--bg-code); padding: 1px 5px; border-radius: 3px; }
    </style>
  </head>
  """

  @doc """
  Returns the full `<!DOCTYPE html>` + `<head>` block (including the
  Geist font import + the design-tokens CSS + the dark-mode rules)
  plus the opening `<html lang="en">` tag.

  `title` is HTML-escaped before substitution; pass the
  already-gettext'd page title.
  """
  @spec head_html(String.t()) :: String.t()
  def head_html(title) when is_binary(title) do
    String.replace(@head_template, "{{TITLE}}", esc(title))
  end
end

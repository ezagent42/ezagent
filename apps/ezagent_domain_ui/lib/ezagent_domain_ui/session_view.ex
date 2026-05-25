defmodule Ezagent.UI.SessionView do
  @moduledoc """
  Phase 8b — Session view extension point.

  A SessionView is a Phoenix.Component that renders ONE way of looking
  at a session in the Main Window's main area (between SessionEditor
  header and input). Each view declares which sessions it applies to
  via `applies_to/1`.

  Plugins register views in their Application.start/2 via
  `Ezagent.UI.SessionViewRegistry.register/1`.

  Default views shipped:
  - `:conversation` (in ezagent_plugin_liveview) — chat message stream
  - `:pty` (in ezagent_plugin_cc) — xterm.js terminal, only for sessions
    that have a `entity://agent/team-alpha/cc_*` member

  ## Namespacing

  Lives under `Ezagent.UI.*` deliberately — `Ezagent.Behavior` is the
  dispatch-side Kind behaviour contract (totally different shape). The
  UI namespace keeps the two extension points unambiguous.
  """

  @doc "Short identifier for the view (atom)."
  @callback id() :: atom()

  @doc "Display label for the view-switcher button."
  @callback label() :: String.t()

  @doc "Heroicon name for the view-switcher button."
  @callback icon() :: String.t()

  @doc """
  Does this view apply to the given session?
  Called once per session render to decide which view-switcher buttons
  show up. Should be cheap (e.g. lookup session members + check kind types).
  """
  @callback applies_to?(session_uri :: URI.t()) :: boolean()

  @doc """
  Phoenix.Component-style render. Receives assigns including
  session_uri + caller_uri + current_member_options + any view-specific
  state owned by the wrapping LV.

  The view is rendered INSIDE the SessionEditor's main area (between
  header and input). Views don't render their own header/input.
  """
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()
end

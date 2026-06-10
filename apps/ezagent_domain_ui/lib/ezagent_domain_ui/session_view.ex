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

  @doc """
  P2 (unified view contract) — does this app declare an EXTERNAL render
  target (a `customer_tree`/json-render projection consumed by the SPA via
  an ExternalAdapter), in addition to (or instead of) the internal LiveView
  `render/1`?

  Optional. A view that does not implement this callback is INTERNAL-ONLY
  (the default, e.g. ConversationView) — the registry treats a missing
  callback as `false`. A view that returns `true` MUST implement
  `external_render/1`.

  The internal and external renders are two TARGETS behind ONE view
  declaration (spec §3.4, option A). This callback declares the external
  target exists; it does not change how the internal `render/1` works.
  """
  @callback external_render?() :: boolean()

  @doc """
  P2 — produce the EXTERNAL render for `session_uri`: the json-render tree
  (a plain map, the `customer_tree` shape) the SPA consumes. Returns `nil`
  when there is nothing to render externally yet (e.g. no approved/committed
  surface version).

  Optional — only views whose `external_render?/0` returns `true` need
  implement it. This is the json-render DATA tree, NOT a `Phoenix.Component`
  (the internal `render/1` returns the LiveView rendered struct; the external
  target is a serializable map rendered by the SPA / an ExternalAdapter).

  P2 NOTE: this is the per-app DECLARATION of the external render. It does
  NOT change the customer-delivery pipeline (CustomerFeed / CustomerChannel)
  — that is P2.5/P3. An implementation reuses the app's existing projection
  (e.g. socialware delegates to `Ezagent.Behavior.Surface.customer_tree/1`).
  """
  @callback external_render(session_uri :: URI.t()) :: map() | nil

  @optional_callbacks external_render?: 0, external_render: 1
end

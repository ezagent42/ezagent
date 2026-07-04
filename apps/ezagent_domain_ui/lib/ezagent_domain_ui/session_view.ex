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
  - `:conversation` — chat message stream
  - `:pty` (in ezagent_plugin_cc) — xterm.js terminal, only for sessions
    that have a `entity://agent/team-alpha/cc_*` member

  ## Namespacing

  Lives under `Ezagent.UI.*` deliberately — `Ezagent.ActionSet` is the
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
  target (a `external_tree`/json-render projection consumed by the SPA via
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
  (a plain map, the `external_tree` shape) the SPA consumes. Returns `nil`
  when there is nothing to render externally yet (e.g. no approved/committed
  surface version).

  Optional — only views whose `external_render?/0` returns `true` need
  implement it. This is the json-render DATA tree, NOT a `Phoenix.Component`
  (the internal `render/1` returns the LiveView rendered struct; the external
  target is a serializable map rendered by the SPA / an ExternalAdapter).

  P2 NOTE: this is the per-app DECLARATION of the external render. It does
  NOT change the customer-delivery pipeline (ExternalFeed / ExternalFeedChannel)
  — that is P2.5/P3. An implementation reuses the app's existing projection
  (e.g. socialware delegates to `Ezagent.ActionSet.Surface.external_tree/1`).
  """
  @callback external_render(session_uri :: URI.t()) :: map() | nil

  @doc """
  T2-2b — the backing **view read ActionSet** whose `<sw>_render` cap gates this
  view's visibility, or `nil` for a view that is NOT cap-gated (legacy/operator
  views). A cap-gated socialware view (hello page, kanban board) returns its
  cap-only render ActionSet module (e.g. `Ezagent.ActionSet.HelloRender`).

  Optional — a view that does not implement this callback is treated as
  non-cap-gated (`authorize_view/3` returns `true` for it). A view that returns a
  module is gated: `authorize_view/3` requires the caller to hold that ActionSet's
  render cap on the session.
  """
  @callback view_behavior() :: module() | nil

  @optional_callbacks external_render?: 0, external_render: 1, view_behavior: 0

  alias Ezagent.Capability

  @doc """
  T2-2b — the UNIFIED view-authorization gate (decision 2). Does `caller` hold
  the render cap for `view_module` on `session_uri`?

  This is the single point every render entry (`applicable_views`, `render`,
  `external_render`, adapter render, channel refresh) routes through — sunk into
  the contract so all `SessionView` implementations are caller-aware by
  construction, with NO direct `:surface`-slice read bypassing it.

  - A view with no declared `view_behavior/0` (or `nil`) is NOT cap-gated → `true`.
  - A view with a backing ActionSet is gated: the caller must hold a cap matching
    the ActionSet's `<sw>_render` action on this concrete session. A `nil` caller
    (no identity) is denied for a gated view.

  Coarse-grained openness (`Definition.visibility_policy`, whether an anon is even
  minted) is the OTHER, orthogonal gate; this is the fine-grained per-view gate.
  """
  @spec authorize_view(module(), URI.t() | nil, URI.t()) :: boolean()
  def authorize_view(view_module, caller, %URI{} = session_uri) when is_atom(view_module) do
    case backing_behavior(view_module) do
      nil -> true
      behavior -> caller_holds_render_cap?(behavior, caller, session_uri)
    end
  end

  @doc """
  The backing render ActionSet of `view_module`, or `nil` when the view is not
  cap-gated. Public so the arch gate + `Installation.anon_view_caps/1` can reason
  about a view's declared render cap uniformly.
  """
  @spec backing_behavior(module()) :: module() | nil
  def backing_behavior(view_module) when is_atom(view_module) do
    if Code.ensure_loaded?(view_module) and function_exported?(view_module, :view_behavior, 0) do
      case view_module.view_behavior() do
        mod when is_atom(mod) and not is_nil(mod) -> mod
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  @doc """
  The concrete render caps a caller must hold to view `behavior`'s render on
  `session_uri` — one per action the ActionSet declares
  (`cap(:session, behavior, action, <session>, <ws>)`). This is the SAME shape
  `Installation.anon_view_caps/1` mints and the anon is born with, so the mint
  and the gate agree by construction.
  """
  @spec render_needed_caps(module(), URI.t()) :: [Capability.t()]
  def render_needed_caps(behavior, %URI{} = session_uri) when is_atom(behavior) do
    instance = Ezagent.URI.instance(session_uri)
    workspace = Capability.workspace_of(session_uri)

    for action <- behavior_actions(behavior) do
      Capability.cap(:session, behavior, action, instance, workspace)
    end
  end

  defp behavior_actions(behavior) do
    if Code.ensure_loaded?(behavior) and function_exported?(behavior, :actions, 0) do
      behavior.actions()
    else
      []
    end
  rescue
    _ -> []
  end

  defp caller_holds_render_cap?(behavior, %URI{} = caller, %URI{} = session_uri) do
    needed = render_needed_caps(behavior, session_uri)
    held = safe_held_caps(caller)

    needed != [] and
      Enum.any?(needed, fn need -> Enum.any?(held, &Capability.matches?(&1, need)) end)
  end

  defp caller_holds_render_cap?(_behavior, _caller, _session), do: false

  defp safe_held_caps(%URI{} = caller) do
    Ezagent.Identity.list_caps_for(caller)
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end

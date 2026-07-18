defmodule Ezagent.World.ErrorCards do
  @moduledoc """
  G5 source 2 — async agent-reply error cards.

  When an agent fails while generating a reply, the failure arrives as DATA
  on the reply message body (`Ezagent.Agent.ErrorSignal` payload under
  `error`), NOT on the sync dispatch return path. This module owns the
  world-side consumption: decode the payload, run the SAME shared pipeline
  the sync path uses (`ErrorMatcher` → `ErrorRenderer`), and attach the
  per-viewer Layer 1/2/3 card to the message row. It also hosts the Layer 2
  "notify the founder" flow shared with the sync path.

  Split out of `ConversationData`/`WorldLive` so the G5 concern lives in one
  place (and both stay under the `oversized_modules_gt_1000` arch gate).
  """

  alias Ezagent.Agent.ErrorSignal

  @doc "The structured agent-error payload on a reply body; dual-key like `body_text/1`."
  @spec payload(map() | nil) :: map() | nil
  def payload(%{error: e}) when is_map(e), do: e
  def payload(%{"error" => e}) when is_map(e), do: e
  def payload(_), do: nil

  @doc """
  Per-viewer context for rendering agent-error cards: whether THIS viewer can
  fix (admin check — mirrors the sync dispatch-error path) + the workspace
  founder's display name. Compute once per render pass; `enrich/3` consumes
  it per row.
  """
  @spec viewer_ctx(URI.t() | nil, Enumerable.t(), URI.t() | nil) :: map()
  def viewer_ctx(caller_uri, caller_caps, workspace_uri) do
    %{
      user_can_fix: viewer_admin?(caller_uri, caller_caps),
      fix_owner_display_name: founder_display_name(workspace_uri)
    }
  end

  @doc "Lazy `viewer_ctx/3` from a LiveView socket — resolved only when a row carries an error payload."
  @spec live_viewer_ctx(Phoenix.LiveView.Socket.t()) :: (-> map())
  def live_viewer_ctx(socket) do
    assigns = socket.assigns

    fn ->
      viewer_ctx(
        Map.get(assigns, :current_entity_uri),
        Map.get(assigns, :current_caps, MapSet.new()),
        Map.get(assigns, :current_workspace_uri)
      )
    end
  end

  @doc "Resolve a `viewer_ctx/3` map or its lazy 0-arity producer."
  @spec resolve_ctx(map() | (-> map())) :: map()
  def resolve_ctx(%{} = ctx), do: ctx
  def resolve_ctx(fun) when is_function(fun, 0), do: fun.()

  @doc """
  Attach the per-viewer G5 error card to a message row when its body carries
  a structured agent-error payload; pass-through otherwise.

  Decode → `ErrorMatcher` → `ErrorRenderer.render/2`, the SAME pipeline the
  sync dispatch path uses; a decode failure or unregistered reason still
  renders the Layer 3 card — never a silent drop. `issue_ref` (the message
  id) keeps Layer 3 issue ids deterministic across re-renders of durable
  history.
  """
  @spec enrich(map(), map() | nil, map() | (-> map())) :: map()
  def enrich(row, body, viewer_ctx) when is_map(row) do
    case payload(body) do
      nil ->
        row

      wire ->
        # Sender gate (adversarial review #1 — forgeable error cards):
        # only enrich rows whose sender is an agent entity. The sender_kind
        # is computed server-side from the sender URI by `message_row/2`
        # via `URI.type?(uri, :agent)`, so a user/plugin can NOT sell a
        # user message as an agent-authored error. A full platform-level
        # provenance check (`session.send` validating sender==caller) is a
        # follow-up — this guard closes the shallow spoof surface.
        if Map.get(row, "sender_kind") != "agent" do
          row
        else
          ctx = resolve_ctx(viewer_ctx)

          reason =
            case ErrorSignal.decode(wire) do
              {:ok, r} -> r
              :error -> nil
            end

          code = if reason != nil, do: Ezagent.World.ErrorMatcher.match({:error, reason})

          card =
            Ezagent.World.ErrorRenderer.render(code,
              user_can_fix: Map.get(ctx, :user_can_fix, false),
              fix_owner_display_name: Map.get(ctx, :fix_owner_display_name),
              issue_ref: Map.get(row, "id")
            )

          Map.put(row, "error_card", card)
        end
    end
  end

  @doc """
  Layer 2 "send reminder": notify the workspace founder about a fix request.
  Returns `:ok` | `:no_founder`. Shared by the sync dispatch-error card and
  the async agent-error card (both emit the same `notification.send` action).
  """
  @spec send_fix_request(Phoenix.LiveView.Socket.t(), map()) :: :ok | :no_founder
  def send_fix_request(socket, body) when is_map(body) do
    caller = Map.get(socket.assigns, :current_entity_uri)
    workspace_uri = Map.get(socket.assigns, :current_workspace_uri)

    case founder_uri(workspace_uri) do
      %URI{} = founder_uri ->
        Ezagent.Notifications.notify(founder_uri, %{
          type: :error_fix_request,
          body:
            Map.merge(body, %{
              caller_name: entity_display_name(caller),
              workspace: entity_display_name(workspace_uri)
            }),
          source: __MODULE__
        })

        :ok

      nil ->
        :no_founder
    end
  end

  @doc "The workspace founder's entity URI (first member), `nil` when unresolvable."
  @spec founder_uri(URI.t() | nil) :: URI.t() | nil
  def founder_uri(%URI{} = ws_uri) do
    case workspace_record(ws_uri) do
      %{members: [%URI{} = founder | _]} -> founder
      _ -> nil
    end
  end

  def founder_uri(_), do: nil

  @doc """
  The workspace founder's display name (first member), `"workspace founder"`
  fallback. Shared by the sync dispatch-error path (`ConversationActions`)
  and the async agent-error card path.
  """
  @spec founder_display_name(URI.t() | nil) :: String.t()
  def founder_display_name(ws_uri) do
    case founder_uri(ws_uri) do
      %URI{} = founder ->
        case Ezagent.URI.name(founder) do
          {:ok, display} -> display
          _ -> "workspace founder"
        end

      nil ->
        "workspace founder"
    end
  end

  @doc "Best-effort display name for an entity/workspace URI (`\"unknown\"` fallback)."
  @spec entity_display_name(URI.t() | term()) :: String.t()
  def entity_display_name(%URI{} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, name} -> name
      _ -> Ezagent.URI.stable_key(uri)
    end
  end

  def entity_display_name(_), do: "unknown"

  defp viewer_admin?(%URI{} = caller, caps) do
    Ezagent.Identity.AdminAuthority.admin?(caller, caps)
  rescue
    _ -> false
  end

  defp viewer_admin?(_, _), do: false

  defp workspace_record(%URI{} = ws_uri) do
    case Ezagent.URI.name(ws_uri) do
      {:ok, name} when is_binary(name) and name != "" ->
        Ezagent.Workspace.Store.get_by_name(name)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end

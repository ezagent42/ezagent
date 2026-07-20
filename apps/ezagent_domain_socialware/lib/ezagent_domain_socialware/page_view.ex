defmodule EzagentDomainSocialware.PageView do
  @moduledoc """
  Internal SessionView for the socialware page surface.

  Renders the latest retained page version. External rendering is a later
  React/json-render surface and follows `Ezagent.ActionSet.Surface.external_tree/1`.

  ## Read-plane authz (PR-2)

  Every `:surface`-slice read routes through the
  `Ezagent.Socialware.SessionReads.external_surface/2` chokepoint, which
  authorizes the caller FIRST (strict membership, or the session's
  `public_view` open policy). The `SessionView` behaviour's caller-less
  `/1` callbacks delegate to the caller-aware `/2` forms with a `nil` caller —
  fail-closed: only a `public_view` session's surface is readable without a
  principal.
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  alias Ezagent.ActionSet.Surface
  alias Ezagent.Socialware.SessionReads

  @impl true
  def id, do: :page

  @impl true
  def label, do: "Page"

  @impl true
  def icon, do: "panel-top"

  @impl true
  def applies_to?(%URI{} = session_uri), do: applies_to?(session_uri, nil)

  def applies_to?(_), do: false

  @doc """
  Caller-aware `applies_to?`: true when `caller` may read `session_uri`'s
  surface through the `SessionReads` chokepoint (strict membership, or the
  public-view open policy). Fail-closed on any error.
  """
  @spec applies_to?(URI.t(), URI.t() | term()) :: boolean()
  def applies_to?(%URI{} = session_uri, caller) do
    case SessionReads.external_surface(caller, session_uri) do
      {:ok, surface} when is_map(surface) -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def applies_to?(_, _), do: false

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:surface, fn ->
        load_surface(assigns[:session_uri], assigns[:caller_uri] || assigns[:caller])
      end)

    assigns = assign(assigns, :tree, Surface.internal_tree(assigns[:surface] || %{}))

    ~H"""
    <div id="socialware-page-view" class="flex-1 overflow-auto bg-white dark:bg-zinc-950 min-h-0">
      <div
        :if={is_nil(@tree)}
        id="socialware-page-empty"
        class="h-full min-h-64 flex items-center justify-center text-sm text-zinc-500 dark:text-zinc-400"
      >
        No page version yet.
      </div>

      <div :if={not is_nil(@tree)} id="socialware-page-tree" class="mx-auto max-w-5xl p-5">
        <.render_node node={@tree} />
      </div>
    </div>
    """
  end

  @impl true
  def external_render?, do: true

  @impl true
  def external_render(%URI{} = session_uri), do: external_render(session_uri, nil)

  def external_render(_), do: nil

  @doc """
  Caller-aware external render: the json-render tree for `session_uri`'s
  surface, read through the `SessionReads` chokepoint. Fail-closed: a caller
  with no read authority gets `nil`.
  """
  @spec external_render(URI.t(), URI.t() | term()) :: map() | nil
  def external_render(%URI{} = session_uri, caller) do
    case SessionReads.external_surface(caller, session_uri) do
      {:ok, surface} -> Surface.external_tree(surface)
      {:error, _} -> nil
    end
  end

  def external_render(_, _), do: nil

  defp render_node(assigns) do
    assigns = assign(assigns, :node_type, node_type(assigns.node))

    ~H"""
    <%= case @node_type do %>
      <% "text" -> %>
        <p class="my-2 text-sm leading-6 text-zinc-900 dark:text-zinc-100 whitespace-pre-wrap">
          {text_value(@node)}
        </p>
      <% "container" -> %>
        <section class="my-3 space-y-3">
          <.render_node :for={child <- node_children(@node)} node={child} />
        </section>
      <% "table" -> %>
        <div class="my-3 overflow-x-auto">
          <table class="min-w-full border-collapse text-sm">
            <thead>
              <tr class="border-b border-zinc-200 dark:border-zinc-800">
                <th
                  :for={header <- table_headers(@node)}
                  class="px-3 py-2 text-left font-semibold text-zinc-700 dark:text-zinc-300"
                >
                  {header}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- table_rows(@node)}
                class="border-b border-zinc-100 dark:border-zinc-900"
              >
                <td :for={cell <- row} class="px-3 py-2 text-zinc-900 dark:text-zinc-100">
                  {cell}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% _ -> %>
        <div class="my-2 rounded border border-dashed border-zinc-300 dark:border-zinc-700 p-3 text-xs text-zinc-500">
          Unsupported node: {inspect(@node_type)}
        </div>
    <% end %>
    """
  end

  # The surface read routes through the SessionReads chokepoint (PR-2):
  # authorized FIRST (strict membership or the public-view open policy),
  # fail-closed `%{}` (the "No page version yet" empty state) for a caller
  # with no read authority.
  defp load_surface(%URI{} = session_uri, caller) do
    case SessionReads.external_surface(caller, session_uri) do
      {:ok, surface} -> surface
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp load_surface(_, _), do: %{}

  defp node_type(node), do: node_field(node, :type)

  defp node_children(node) do
    case node_field(node, :children) do
      children when is_list(children) -> children
      _ -> []
    end
  end

  defp text_value(node) do
    node
    |> node_props()
    |> map_field(:text)
    |> to_display_string()
  end

  defp table_headers(node) do
    node
    |> node_props()
    |> map_field(:headers)
    |> list_of_strings()
  end

  defp table_rows(node) do
    node
    |> node_props()
    |> map_field(:rows)
    |> case do
      rows when is_list(rows) ->
        Enum.map(rows, &list_of_strings/1)

      _ ->
        []
    end
  end

  defp node_props(node) do
    case node_field(node, :props) do
      props when is_map(props) -> props
      _ -> %{}
    end
  end

  defp node_field(map, key) when is_map(map), do: map_field(map, key)
  defp node_field(_other, _key), do: nil

  defp map_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp to_display_string(value) when is_binary(value), do: value
  defp to_display_string(value) when is_atom(value), do: Atom.to_string(value)
  defp to_display_string(value) when is_number(value), do: to_string(value)
  defp to_display_string(nil), do: ""
  defp to_display_string(value), do: inspect(value)

  defp list_of_strings(values) when is_list(values), do: Enum.map(values, &to_display_string/1)
  defp list_of_strings(_), do: []
end

defmodule EzagentPluginHello.Spec do
  @moduledoc """
  The hello `@json-render` page-spec contract: a **catalog-constrained**
  `{"type", "props", "children"}` node tree.

  This is the single source of truth shared by three parties:

    * the **builder prompt** (`EzagentPluginHello.Prompts`) tells the LLM it may
      only emit nodes from `catalog/0`;
    * this module **validates** an emitted spec against the catalog (the safety
      property — the AI can't escape the catalog; an out-of-catalog node is
      rejected, never rendered);
    * the **renderer** (`apps/ezagent_plugin_hello/assets`, the `@json-render`
      island) renders exactly these types.

  A "tree" is the `%{type, props, children}` map stored as a `Behavior.Surface`
  version (`Surface` calls it `tree`). It is born ONLY via
  `Surface.put_version/2`, driven by `EzagentPluginHello.TurnDriver`.

  Phase 0 catalog v0 is intentionally minimal (page/section/heading/text/
  button/image/card); it grows by demand (handoff §10.2). Node props are kept
  string-keyed (JSON round-trips through `MessageStore`/snapshots as strings).
  """

  # Catalog — the @json-render/shadcn component set (36). Container types (with a
  # `default` slot) take `children`; leaves carry content in props. The renderer
  # (zod) validates props; this list gates the allowed TYPES + documents props for
  # the prompt. `className` (where present) lets the model add Tailwind utilities.
  @catalog %{
    # layout containers
    "Stack" => %{props: ["direction", "gap", "align", "justify", "className"], container?: true},
    "Grid" => %{props: ["columns", "gap", "className"], container?: true},
    "Card" => %{
      props: ["title", "description", "maxWidth", "centered", "className"],
      container?: true
    },
    # content leaves
    "Heading" => %{props: ["text", "level"], container?: false},
    "Text" => %{props: ["text", "variant"], container?: false},
    "Button" => %{props: ["label", "variant", "disabled"], container?: false},
    "Link" => %{props: ["label", "href"], container?: false},
    "Image" => %{props: ["src", "alt", "width", "height"], container?: false},
    "Badge" => %{props: ["text", "variant"], container?: false},
    "Avatar" => %{props: ["src", "name", "size"], container?: false},
    "Alert" => %{props: ["title", "message", "type"], container?: false},
    "Separator" => %{props: ["orientation"], container?: false},
    # disclosure / navigation
    "Tabs" => %{props: ["tabs", "defaultValue", "value"], container?: true},
    "Accordion" => %{props: ["items", "type"], container?: false},
    "Collapsible" => %{props: ["title", "defaultOpen"], container?: true},
    "Carousel" => %{props: ["items"], container?: false},
    "Table" => %{props: ["columns", "rows", "caption"], container?: false},
    "Dialog" => %{props: ["title", "description", "openPath"], container?: true},
    "Drawer" => %{props: ["title", "description", "openPath"], container?: true},
    "Popover" => %{props: ["trigger", "content"], container?: false},
    "Tooltip" => %{props: ["content", "text"], container?: false},
    "DropdownMenu" => %{props: ["label", "items", "value"], container?: false},
    "Pagination" => %{props: ["totalPages", "page"], container?: false},
    # feedback
    "Progress" => %{props: ["value", "max", "label"], container?: false},
    "Skeleton" => %{props: ["width", "height", "rounded"], container?: false},
    "Spinner" => %{props: ["size", "label"], container?: false},
    # form controls
    "Input" => %{props: ["label", "name", "type", "placeholder", "value"], container?: false},
    "Textarea" => %{props: ["label", "name", "placeholder", "rows", "value"], container?: false},
    "Select" => %{props: ["label", "name", "options", "placeholder", "value"], container?: false},
    "Checkbox" => %{props: ["label", "name", "checked"], container?: false},
    "Radio" => %{props: ["label", "name", "options", "value"], container?: false},
    "Switch" => %{props: ["label", "name", "checked"], container?: false},
    "Slider" => %{props: ["label", "min", "max", "step", "value"], container?: false},
    "Toggle" => %{props: ["label", "pressed", "variant"], container?: false},
    "ToggleGroup" => %{props: ["items", "type", "value"], container?: false},
    "ButtonGroup" => %{props: ["buttons", "selected"], container?: false}
  }

  @doc "The allowed component catalog (type → %{props, container?})."
  @spec catalog() :: map()
  def catalog, do: @catalog

  @doc "The allowed type names, for the prompt + validation."
  @spec types() :: [String.t()]
  def types, do: Map.keys(@catalog)

  @doc """
  Extract a spec map from a raw LLM `content` string. Accepts a bare JSON
  object or one wrapped in a ```json … ``` (or ``` … ```) fence. Returns
  `{:ok, spec}` | `{:error, reason}`. Does NOT validate the catalog — call
  `validate/1` on the result. For a completion that stops immediately after a
  structural delimiter, it can append only the matching closing delimiters;
  it never repairs an open string or an incomplete JSON value.
  """
  @spec extract(String.t()) :: {:ok, map()} | {:error, term()}
  def extract(content) when is_binary(content) do
    json =
      case Regex.run(~r/```(?:json)?\s*(\{.*\})\s*```/s, content) do
        [_, captured] -> captured
        _ -> String.trim(content)
      end

    case Jason.decode(json) do
      {:ok, %{} = spec} -> {:ok, spec}
      {:ok, other} -> {:error, {:not_an_object, other}}
      {:error, reason} -> recover_terminal_delimiters(json, reason)
    end
  end

  def extract(_), do: {:error, :not_a_string}

  # A streamed completion can finish after emitting every semantic JSON token
  # but before its final structural delimiters arrive. Recover only that narrow
  # shape: no open string, no mismatched delimiter, and an append-only suffix of
  # `]`/`}`. Any other malformed JSON keeps its original parse failure.
  defp recover_terminal_delimiters(json, original_reason) do
    with true <- terminal_delimiter?(json),
         {:ok, [_ | _] = opens} <- delimiter_stack(json),
         suffix <- Enum.map_join(opens, &closing_delimiter/1),
         {:ok, %{} = spec} <- Jason.decode(json <> suffix) do
      {:ok, spec}
    else
      {:ok, []} -> {:error, {:json, original_reason}}
      _ -> {:error, {:json, original_reason}}
    end
  end

  defp terminal_delimiter?(json) do
    trimmed = String.trim_trailing(json)
    String.ends_with?(trimmed, "}") or String.ends_with?(trimmed, "]")
  end

  defp delimiter_stack(json) when is_binary(json), do: scan_delimiters(json, [], false, false)

  defp scan_delimiters(<<>>, opens, false, false), do: {:ok, opens}
  defp scan_delimiters(<<>>, _opens, true, _escaped?), do: :unterminated_string

  defp scan_delimiters(<<"\\", rest::binary>>, opens, true, false),
    do: scan_delimiters(rest, opens, true, true)

  defp scan_delimiters(<<_codepoint::utf8, rest::binary>>, opens, true, true),
    do: scan_delimiters(rest, opens, true, false)

  defp scan_delimiters(<<"\"", rest::binary>>, opens, true, false),
    do: scan_delimiters(rest, opens, false, false)

  defp scan_delimiters(<<_codepoint::utf8, rest::binary>>, opens, true, false),
    do: scan_delimiters(rest, opens, true, false)

  defp scan_delimiters(<<"\"", rest::binary>>, opens, false, false),
    do: scan_delimiters(rest, opens, true, false)

  defp scan_delimiters(<<"{", rest::binary>>, opens, false, false),
    do: scan_delimiters(rest, [:object | opens], false, false)

  defp scan_delimiters(<<"[", rest::binary>>, opens, false, false),
    do: scan_delimiters(rest, [:array | opens], false, false)

  defp scan_delimiters(<<"}", rest::binary>>, [:object | opens], false, false),
    do: scan_delimiters(rest, opens, false, false)

  defp scan_delimiters(<<"]", rest::binary>>, [:array | opens], false, false),
    do: scan_delimiters(rest, opens, false, false)

  defp scan_delimiters(<<"}", _rest::binary>>, _opens, false, false), do: :mismatched_delimiter
  defp scan_delimiters(<<"]", _rest::binary>>, _opens, false, false), do: :mismatched_delimiter

  defp scan_delimiters(<<_codepoint::utf8, rest::binary>>, opens, false, false),
    do: scan_delimiters(rest, opens, false, false)

  defp closing_delimiter(:object), do: "}"
  defp closing_delimiter(:array), do: "]"

  @doc """
  Validate that `spec` is a tree using ONLY catalog node types. Returns
  `{:ok, spec}` | `{:error, {:unknown_type, t}}` | `{:error, reason}`. This is
  the catalog-constraint chokepoint — an out-of-catalog node fails closed.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(%{"type" => type} = node) when is_binary(type) do
    cond do
      not Map.has_key?(@catalog, type) ->
        {:error, {:unknown_type, type}}

      true ->
        children = Map.get(node, "children", [])

        cond do
          not is_list(children) ->
            {:error, {:children_not_a_list, type}}

          true ->
            Enum.reduce_while(children, {:ok, node}, fn child, acc ->
              case validate(child) do
                {:ok, _} -> {:cont, acc}
                {:error, _} = err -> {:halt, err}
              end
            end)
        end
    end
  end

  def validate(%{} = node), do: {:error, {:missing_type, node}}
  def validate(other), do: {:error, {:not_a_node, other}}

  @doc """
  Assemble `sections` (an ordered list of worker-produced page fragments — each a
  catalog node map, typically a `section`) under one `page` root titled `title`,
  then validate the whole tree. Returns `{:ok, page}` | `{:error, reason}`.

  This is the Phase-1 fan-out compose step: the orchestrator concatenates each
  worker's sub-tree into `page.children` and validates ONCE. Because `validate/1`
  recurses, the assembled page is rejected if ANY worker emitted an out-of-catalog
  node — the same fail-closed safety as a single generation, so one bad worker
  never lands a page.
  """
  @spec compose_page(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def compose_page(title, sections) when is_binary(title) and is_list(sections) do
    page = %{
      "type" => "Stack",
      "props" => %{"direction" => "vertical", "gap" => "lg", "title" => title},
      "children" => sections
    }

    validate(page)
  end

  def compose_page(_title, _sections), do: {:error, :bad_args}

  @doc "A minimal default page used when a hello session has no generated page yet."
  @spec seed() :: map()
  def seed do
    %{
      "type" => "Stack",
      "props" => %{
        "direction" => "vertical",
        "gap" => "md",
        "className" => "p-8",
        "title" => "Hello"
      },
      "children" => [
        %{"type" => "Heading", "props" => %{"text" => "Hello 👋", "level" => 1}, "children" => []},
        %{
          "type" => "Text",
          "props" => %{"text" => "Tell the builder what page you want."},
          "children" => []
        }
      ]
    }
  end
end

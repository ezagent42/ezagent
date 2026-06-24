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

  # Catalog v0 — allowed node types → the prop keys the renderer honors.
  # `children` is allowed on the container-ish types (page/section/card).
  @catalog %{
    # primitives
    "page" => %{props: ["title"], container?: true},
    "section" => %{props: ["layout", "tone", "title"], container?: true},
    "card" => %{props: ["title"], container?: true},
    "heading" => %{props: ["text", "level"], container?: false},
    "text" => %{props: ["text"], container?: false},
    "button" => %{props: ["label", "href"], container?: false},
    "image" => %{props: ["src", "alt"], container?: false},
    # block-level "official-site" components — each renders a full-width, designed
    # section. `tone` ("default"|"muted"|"dark"|"brand") alternates backgrounds;
    # `icon` is an icon name (shield/zap/rocket/lock/globe/chart/users/cloud/code/
    # gauge/star/check/heart/sparkles/clock/layers).
    "nav" => %{props: ["brand"], container?: true},
    "banner" => %{props: ["text"], container?: false},
    "hero" => %{props: ["title", "subtitle", "cta_label", "cta_href", "badge"], container?: false},
    "features" => %{props: ["title", "subtitle", "tone"], container?: true},
    "feature" => %{props: ["title", "text", "icon"], container?: false},
    "split" => %{props: ["title", "text", "cta_label", "cta_href", "reverse", "icon", "tone"], container?: false},
    "stats" => %{props: ["title", "tone"], container?: true},
    "stat" => %{props: ["value", "label"], container?: false},
    "testimonials" => %{props: ["title", "tone"], container?: true},
    "testimonial" => %{props: ["quote", "author", "role"], container?: false},
    "logos" => %{props: ["title", "tone"], container?: true},
    "logo" => %{props: ["name"], container?: false},
    "pricing" => %{props: ["title", "subtitle", "tone"], container?: true},
    "plan" => %{props: ["name", "price", "period", "cta_label", "featured"], container?: true},
    "faq" => %{props: ["title", "tone"], container?: true},
    "qa" => %{props: ["question", "answer"], container?: false},
    "steps" => %{props: ["title", "tone"], container?: true},
    "step" => %{props: ["title", "text"], container?: false},
    "cta" => %{props: ["title", "text", "button_label", "button_href", "tone"], container?: false},
    "footer" => %{props: ["text"], container?: false}
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
  `validate/1` on the result.
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
      {:error, reason} -> {:error, {:json, reason}}
    end
  end

  def extract(_), do: {:error, :not_a_string}

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
      "type" => "page",
      "props" => %{"title" => title},
      "children" => sections
    }

    validate(page)
  end

  def compose_page(_title, _sections), do: {:error, :bad_args}

  @doc "A minimal default page used when a hello session has no generated page yet."
  @spec seed() :: map()
  def seed do
    %{
      "type" => "page",
      "props" => %{"title" => "Hello"},
      "children" => [
        %{"type" => "heading", "props" => %{"text" => "Hello 👋", "level" => 1}, "children" => []},
        %{
          "type" => "text",
          "props" => %{"text" => "Tell the builder what page you want."},
          "children" => []
        }
      ]
    }
  end
end

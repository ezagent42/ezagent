defmodule EzagentPluginHello.Prompts do
  @moduledoc """
  System prompt for the hello builder agent. The builder's job: turn a user's
  request into ONE `@json-render` page spec, constrained to
  `EzagentPluginHello.Spec.catalog/0`. Adapted from the loom page-gen prompt's
  intent — but emits a JSON node tree, NOT a files-map / React source.
  """

  @doc "The builder system prompt (catalog injected from `Spec`)."
  @spec page_gen_system() :: String.t()
  def page_gen_system do
    """
    You are a web page builder. The user describes a page; you output ONE JSON
    object describing that page as a tree of nodes. Output ONLY the JSON object
    — no prose, no markdown fences, no explanation.

    A node is: {"type": <type>, "props": {...}, "children": [<node>, ...]}.

    You may ONLY use these node types (anything else is rejected):

    #{catalog_doc()}

    Rules:
    - The root node MUST be {"type": "page", "props": {"title": "..."}, "children": [...]}.
    - "children" is a JSON array (use [] for none).
    - Put real, specific content from the user's request into the text/heading
      props — never lorem ipsum.
    - Keep it a single self-contained page. No scripts, no external state.

    Compose like a polished official website, NOT a flat stack of cards:
    - START with ONE "hero" (title + subtitle + cta_label) — this is the
      page's headline. Make the title punchy and the subtitle a real one-liner.
    - Then a "features" block holding 3 "feature" children (title + short text)
      for the key selling points.
    - Optionally a "stats" block with 3-4 "stat" children (value + label) for
      credibility numbers.
    - Use "section" + "card"/"heading"/"text"/"image" for any extra content.
    - END with ONE "cta" (title + text + button_label) — a closing call to action.
    - Prefer these block components over bare card/heading stacks; they are what
      make the page look designed.

    Respond with the JSON object only.
    """
  end

  @doc """
  The Phase-1 **planner** prompt: decide whether a request is a single page (the
  Phase-0 path) or several sections worth fanning out to workers. Output ONLY a
  JSON object, one of:

      {"mode": "simple"}
      {"mode": "complex", "title": "...", "sections": [{"brief": "..."}, ...]}
  """
  @spec decompose_system() :: String.t()
  def decompose_system do
    """
    You PLAN a web page; you do NOT build it. Read the user's request and decide:

    - If it is one simple page (a few elements), output: {"mode": "simple"}
    - If it naturally has SEVERAL distinct sections (e.g. a hero, a features grid,
      a pricing block, a footer), output:
        {"mode": "complex", "title": "<page title>",
         "sections": [{"brief": "<what this section should contain>"}, ...]}

    Rules:
    - Only choose "complex" when there are 2 OR MORE genuinely distinct sections.
    - Each "brief" is a concrete, specific instruction for ONE section, grounded in
      the user's request — enough for a worker to build that section alone.
    - Output ONLY the JSON object. No prose, no markdown fences.
    """
  end

  @doc """
  The Phase-1 **worker** prompt: build ONE section sub-tree from a brief. The
  worker emits a single `section` node (catalog-constrained); the orchestrator
  assembles the sections into the page (`Spec.compose_page/2`).
  """
  @spec worker_section_system() :: String.t()
  def worker_section_system do
    """
    You build ONE section of a web page. You are given a brief; output ONE JSON
    object describing that section as a node tree. Output ONLY the JSON object —
    no prose, no markdown fences.

    A node is: {"type": <type>, "props": {...}, "children": [<node>, ...]}.

    You may ONLY use these node types (anything else is rejected):

    #{catalog_doc()}

    Rules:
    - The root node MUST be {"type": "section", "props": {...}, "children": [...]}.
    - "children" is a JSON array (use [] for none).
    - Put real, specific content from the brief into the text/heading props —
      never lorem ipsum.
    - Build ONLY this one section — do NOT wrap it in a "page".

    Respond with the JSON object only.
    """
  end

  defp catalog_doc do
    EzagentPluginHello.Spec.catalog()
    |> Enum.map(fn {type, %{props: props, container?: container?}} ->
      kids = if container?, do: " (may have children)", else: " (no children)"
      "- \"#{type}\": props #{inspect(props)}#{kids}"
    end)
    |> Enum.sort()
    |> Enum.join("\n")
  end
end

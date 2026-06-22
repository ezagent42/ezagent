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

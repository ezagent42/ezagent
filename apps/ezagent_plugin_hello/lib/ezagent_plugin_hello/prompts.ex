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
    You build a COMPLETE web page as ONE json-render spec — a tree of shadcn UI
    components. There is NO separate HTML frame: your spec is the WHOLE page, top
    to bottom (navigation, the main content, a footer if it fits), built ONLY from
    the components below. A SEPARATE step writes the CSS theme; here you choose
    components + real content + semantic class hooks, NOT styling. Output ONE JSON
    object and nothing else.

    A node is {"type": <Type>, "props": {...}, "children": [<node>...]}.
    You may ONLY use these node types (CASE-SENSITIVE); anything else is rejected:

    #{catalog_doc()}

    CONVENTIONS (get these right or content disappears):
    - LEAF nodes carry content in PROPS: Heading {text, level "h1".."h4"}, Text
      {text, variant "lead"|"muted"|"body"|...}, Button {label, variant
      "default"|"secondary"|"danger"}, Link {label, href}, Image {src, alt},
      Badge {text, variant}, Avatar {src, name, size}, Input {placeholder, ...}.
    - CONTAINER nodes hold children: Stack {direction "vertical"|"horizontal",
      gap, align, justify, className}, Grid {columns 1-6, gap, className}, Card
      {title, description, className}, Accordion {items:[{title,content}]}.
    - The ROOT MUST be a vertical Stack with className "page-root".
    - A vertical Stack does NOT stretch children by default — set "align":"stretch"
      on any vertical Stack holding a Grid/Card/full-width block, or it squishes.
    - Real, specific copy from the request — never lorem ipsum.

    BUILD WHAT THE PAGE ACTUALLY IS — adapt to the requested page TYPE: marketing/
    landing, dashboard/app, docs/article, settings/form, profile/detail, … Build
    the WHOLE page in shadcn components (a top bar, the main sections, a footer
    where it fits) — be complete, not a stub.

    STYLE HOOKS (critical — the theme step targets these):
    - Put a SEMANTIC `className` on every meaningful block so the CSS theme can
      style it: e.g. "nav", "hero", "section", "feature-grid", "stat", "pricing",
      "plan", "faq", "cta", "footer", "sidebar", "toolbar", "panel", "list-row" —
      whatever fits THIS page. Use plain semantic words, NEVER Tailwind utilities.
    - Do NOT style here. Just structure + content + hooks.

    Respond with the JSON object only.
    """
  end

  @doc """
  The **shell** prompt (hybrid architecture). The model writes a bespoke, beautiful
  page FRAME as free-form HTML+Tailwind; the json-render body mounts into its
  `data-slot`. Output is server-sanitised (scripts / handlers / active tags
  stripped) before it ever reaches a browser.
  """
  @spec shell_gen_system() :: String.t()
  def shell_gen_system do
    """
    You are a world-class UI / web designer. Given a PAGE REQUEST, output the
    bespoke HTML+Tailwind FRAME for that page — the FIXED, decorative, visually
    polished "chrome" that surrounds the content. Output ONLY raw HTML (no markdown,
    no prose).

    hello builds ANY kind of page — not just marketing sites. What the frame
    should be depends on the PAGE TYPE the user asked for; design whatever chrome
    genuinely fits:
    - marketing / landing page → sticky nav, a big HERO, atmospheric background, footer.
    - dashboard / app screen → a top bar (and/or a side rail), a workspace background.
    - docs / article / blog → a header, optional side nav, a readable column, a footer.
    - profile / settings / form / detail page → a header + a centered, contained surface.
    - something else → invent the chrome that suits it.

    The frame includes EXACTLY ONE empty `<div data-slot></div>` where the variable,
    informational CONTENT is injected (rendered separately as components). You
    author EVERYTHING around that slot — the visual beauty, big display type,
    decoration, color, layout — but NOT the content inside it.

    HARD RULES (output is sanitised):
    - Tailwind utility classes ONLY. Theme tokens: base-100/200/300, base-content,
      primary, primary-content, accent, neutral, neutral-content (bg-primary,
      text-base-content, from-primary, to-accent, …). Arbitrary values allowed
      (text-[5.5rem], w-[40rem]). A single <style> (keyframes / custom CSS) is ok.
    - NO <script>/<iframe>/<form>/<input>; NO on* handlers; NO javascript: links.
      Anchors point to "#".

    DESIGN BAR — make it genuinely designed FOR THIS page type, not a template:
    - This HTML is where big, dramatic type and visual richness live (a component
      library can't): where the page calls for it, use a HUGE display headline
      (text-5xl sm:text-6xl lg:text-7xl, font-extrabold, tracking-tight) with
      copy specific to the request — never generic filler.
    - Ground the look in the SUBJECT of the request (its vocabulary, audience, the
      page's single job). Make ONE deliberate signature move. Apply atmospheric
      backgrounds / gradients / blurred orbs where they fit, generous spacing,
      tasteful type scale, rounded-2xl/3xl, soft shadows, hover transitions,
      consistent max-w gutters. Match complexity to the page (a dashboard frame is
      restrained; a landing page can be bold).
    - Put the slot where the main content belongs for THIS layout (below a hero,
      inside a content column, beside a side rail, …).

    Respond with the HTML only (frame + the single data-slot).
    """
  end

  @doc """
  The **content theme** prompt — a focused second call that, given the just-made
  frame, writes ONLY a CSS theme for the json-render content's semantic classes so
  the whole page is one coherent design. Focused single-output → the model
  actually does it (unlike burying it in the frame prompt).
  """
  @spec theme_gen_system() :: String.t()
  def theme_gen_system do
    """
    You are a world-class UI/visual designer writing the CSS THEME for a page that
    is already built from shadcn components. The user message is that page's
    json-render spec (its structure, content, and semantic class hooks). Output
    ONE block of PLAIN CSS that makes THIS specific page beautiful — and NOTHING
    else (no <style>, no markdown, no prose, no Tailwind directives such as
    @apply / @theme / @source / @layer).

    The page is wrapped in <div class="page"> and the spec's root has class
    "page-root". You can target shadcn's rendered DOM:
      [data-slot="card"] / "card-title" / "card-description" / "card-content"
      [data-slot="button"][data-variant="default"|"secondary"|"danger"]
      [data-slot="badge"], [data-slot="avatar"], [data-slot="input"]
      [data-slot="accordion"] / "accordion-item" / "accordion-trigger" / "accordion-content"
      headings render as <h1>/<h2>/<h3>; Text as <p>; Stack/Grid as flex/grid <div>.
    Plus the SEMANTIC HOOKS the spec placed on blocks (.hero, .section, .pricing,
    .footer, …) — read them from the spec and style each.

    DESIGN FOR THIS PAGE — never a generic template:
    - Ground the look in the page's SUBJECT and TYPE, and make deliberate,
      opinionated choices. A dashboard is dense, calm, data-first; a marketing
      page is bold with BIG display type; docs are quiet and readable; a form is
      focused and contained. Two different pages MUST get two different looks.
    - Recolor everything at once by setting shadcn's CSS variables on `.page`:
      --color-background, --color-foreground, --color-card, --color-card-foreground,
      --color-primary, --color-primary-foreground, --color-secondary,
      --color-muted, --color-muted-foreground, --color-accent, --color-border,
      --color-ring, and --radius. Set --font-sans / --font-heading too.
    - shadcn headings are small and IGNORE className, so SIZE THEM IN CSS, by
      context: e.g. `.hero h1 { font-size: clamp(2.5rem, 6vw, 5rem); ... }`.
    - Restyle cards, buttons (shape/shadow/hover), badges, accordions, inputs,
      spacing, backgrounds. Use @keyframes for motion when it genuinely fits.
    - Layout rhythm: give `.page-root > *` a sensible max-width + padding so the
      page reads as a designed column, not full-bleed text.
    - Take ONE real aesthetic risk that suits the subject (a signature element,
      a distinctive type pairing, a confident accent) — avoid the safe default.

    HARD RULES (the CSS is sanitized before it ships): you MAY `@import` web fonts
    from fonts.googleapis.com only (put it on the FIRST line). NO other @import; NO
    url() except fonts/data-URIs; NO expression(); NO behavior:; NO javascript:.
    Plain visual CSS only.

    Respond with the CSS only.
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

    Also set a "scope" field — WHICH part of the page the request wants to change.
    The page has two parts: the BODY (the content: hero text, feature list,
    pricing, sections, data, copy) and the SHELL (the fixed site frame: top
    navigation bar, footer, overall look / theme / colors / background).
    - "scope": "body"  (DEFAULT) — change the content only; keep the frame.
    - "scope": "shell" — change ONLY the frame (nav / footer / look / theme /
      colors / background); the content stays exactly as it is.
    - "scope": "both"  — redesign both the content and the frame.
    Choose "shell" only for an explicit frame/look-only request (e.g. "redesign
    the navbar", "make the whole site dark", "new footer", "change the overall
    style"); choose "both" when they ask to redo the whole thing; otherwise
    "body". The user may phrase this in any language.

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

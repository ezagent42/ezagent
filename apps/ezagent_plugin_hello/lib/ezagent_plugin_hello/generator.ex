defmodule EzagentPluginHello.Generator do
  @moduledoc """
  Runs one page-generation turn for the hello builder, off the Behavior's
  GenServer process (so the slow LLM round-trip never blocks dispatch).

  `start/2` spawns a supervised Task (under `EzagentPluginHello.TaskSupervisor`);
  `generate/2` PLANS the request (`decompose/1`) for its EDIT SCOPE (body / shell /
  both) and runs the single-page path: one LLM call → catalog page →
  `TurnDriver.drive/3`. Out-of-catalog output fails closed (`Spec.validate/1`).

  Fan-out (the complex/per-section-worker path) is DISABLED for the shadcn era —
  one `page_gen` call now produces the whole (5–8 section) body, and the per-section
  worker prompt predated shadcn so it produced invalid sub-trees and always fell
  back anyway. `classify_plan/1` therefore always returns `{:simple}`; `decompose/1`
  / `parse_plan/1` still run to extract the edit SCOPE.

  ## API config (Phase 0)

  The provider config comes from env (`HELLO_LLM_API_KEY` | `DEEPSEEK_KEY`,
  `HELLO_LLM_API_URL`, `HELLO_LLM_MODEL`), defaulting to DeepSeek. Storing the
  key on the agent's `:api_keys` slice (the curl-agent model) is a follow-up.
  """

  require Logger

  # User-facing builder narration goes through the plugin-owned gettext backend
  # (#91). No Han-character literals may live in this app's `lib/` — the
  # `CjkLiteralGate` arch test enforces it; the Chinese copy lives in
  # `priv/gettext/zh_CN/LC_MESSAGES/default.po`.
  use Gettext, backend: EzagentPluginHello.Gettext

  alias EzagentPluginHello.{Prompts, Sanitize, ShellCss, Spec, TurnDriver}
  alias EzagentPluginHello.LLM.ApiClient

  @doc "Spawn a supervised Task that generates + lands a page for `user_text`."
  @spec start(URI.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def start(%URI{} = session_uri, user_text) when is_binary(user_text) do
    Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
      generate(session_uri, user_text)
    end)
  end

  @doc """
  Generate a page and land it on `session_uri`'s Surface. A FRESH session (no
  frame yet) generates frame + content in one round; a follow-up edit PLANS its
  scope (`decompose/1`) and regenerates body / shell / both. All content goes
  through the single-page path (`generate_simple/4`) — fan-out is disabled, see the
  moduledoc.
  """
  @spec generate(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(%URI{} = session_uri, user_text) when is_binary(user_text) do
    # Pin the turn's locale for narration: this Task process has no per-request
    # Locale plug, so without this the copy would fall back to the gettext
    # default. Covers every `say` below (all run in this process).
    Gettext.put_locale(EzagentPluginHello.Gettext, "zh_CN")
    builder = builder_uri(session_uri)
    # First-moment acknowledgement (before the slow planner LLM call).
    TurnDriver.say(session_uri, builder, gettext("Got it ✅ understanding your request…"))

    cond do
      # FRESH session (no frame yet) — single round: generate the HTML frame AND
      # the real content together. `reframe: true` makes `land_page` build the
      # frame (styled by this request) alongside the body, so one message yields a
      # complete page (no placeholder-skeleton approval step).
      current_shell_html(session_uri) == "" ->
        generate_simple(session_uri, builder, user_text, true)

      # Follow-up edits to an existing page keep the scoped flow (body/shell/both).
      true ->
        generate_for_scope(session_uri, builder, user_text)
    end
  end

  defp generate_for_scope(session_uri, builder, user_text) do
    {_plan, scope} = decompose(user_text)

    case scope do
      # Shell-only: keep the existing json-render BODY untouched, regenerate just
      # the HTML frame. No page_gen call, so the content the user didn't ask to
      # change stays exactly as-is.
      :shell ->
        TurnDriver.say(
          session_uri,
          builder,
          gettext("🎨 Plan: redesign the frame only (content unchanged).")
        )

        regenerate_shell_only(session_uri, builder, get_title_for_shell(session_uri), user_text)

      # Body (default) or both: run the normal content generation. `reframe?`
      # forces a fresh frame too when the user asked for "both".
      _ ->
        reframe = scope == :both

        if reframe,
          do: TurnDriver.say(session_uri, builder, gettext("🎨 Redesigning the site frame too…"))

        TurnDriver.say(session_uri, builder, gettext("🧭 Plan: single page, direct generation."))
        generate_simple(session_uri, builder, user_text, reframe)
    end
  end

  # The Phase-0 single-page path: one LLM call → one catalog page → Surface.
  defp generate_simple(session_uri, builder, user_text, reframe) do
    TurnDriver.say(session_uri, builder, gettext("🧠 Calling model to generate the page…"))

    with {:ok, %{content: content}} <- call_llm(Prompts.page_gen_system(), user_text),
         {:ok, raw_spec} <- Spec.extract(content),
         {:ok, spec} <- Spec.validate(raw_spec) do
      log_spec(session_uri, spec)

      TurnDriver.say(
        session_uri,
        builder,
        gettext("📦 Structure generated: %{desc}", desc: describe_page(spec))
      )

      land_page(session_uri, builder, spec, user_text, reframe)
    else
      {:error, reason} = err ->
        Logger.warning("hello.Generator: generation failed: #{inspect(reason)}")

        TurnDriver.say(
          session_uri,
          builder,
          gettext("⚠ Generation failed: %{reason}", reason: inspect(reason))
        )

        err
    end
  end

  @type plan :: {:simple} | {:complex, %{title: String.t(), sections: [map()]}}
  @type scope :: :body | :shell | :both

  @doc """
  Plan a request into `{:simple}` or `{:complex, %{title, sections}}` — the
  Phase-1 orchestrator's pre-classification (decision D-1). Calls the planner LLM;
  a failed/ambiguous reply degrades to `{:simple}` so generation always proceeds.
  """
  @spec decompose(String.t()) :: {plan(), scope()}
  def decompose(user_text) when is_binary(user_text) do
    case call_llm(Prompts.decompose_system(), user_text) do
      {:ok, %{content: content}} -> parse_plan(content)
      {:error, _} -> {{:simple}, :body}
    end
  end

  @doc """
  Parse the planner's reply into a plan. Pure. Anything that is not an explicit,
  well-formed `complex` plan with ≥2 usable section briefs degrades to `{:simple}`
  (the hard floor — fan-out is opt-in, only when it clearly pays off). Section ids
  are assigned deterministically (`"s0"`, `"s1"`, …), NEVER taken from the LLM, so
  no untrusted strings become turn subtask keys.
  """
  @spec parse_plan(term()) :: {plan(), scope()}
  def parse_plan(content) when is_binary(content) do
    case Spec.extract(content) do
      {:ok, plan} when is_map(plan) -> {classify_plan(plan), scope_of(plan)}
      _ -> {{:simple}, :body}
    end
  end

  def parse_plan(_), do: {{:simple}, :body}

  defp scope_of(%{"scope" => s}) when s in ["shell", "both"], do: String.to_atom(s)
  defp scope_of(_), do: :body

  # Fan-out (complex) is disabled for the shadcn era — the per-section worker
  # prompt predates shadcn and produces invalid sub-trees, so it always failed and
  # fell back anyway. One page_gen call now produces the whole (5-8 section) body.
  defp classify_plan(_), do: {:simple}

  # Return the bespoke HTML frame (shell) for this session: regenerate it (LLM)
  # when `force` (a "shell"/"both"-scoped request) or none is stored yet;
  # otherwise reuse the stored frame so ordinary content edits leave it untouched.
  defp ensure_shell_html(session_uri, _builder, title, brief, force) do
    existing = current_shell_html(session_uri)

    if not force and existing != "" do
      existing
    else
      brand = if is_binary(title) and title != "", do: title, else: "Website"
      brief = if is_binary(brief), do: String.trim(brief), else: ""

      user_msg =
        if brief == "",
          do: "Brand/title: #{brand}",
          else: "Brand/title: #{brand}\nDesign request (style the frame to match): #{brief}"

      case call_llm(Prompts.shell_gen_system(), user_msg) do
        {:ok, %{content: content}} ->
          # The frame now carries the hero (big design type) + nav + footer. The
          # shadcn content below styles itself, so no separate content-theme pass.
          content |> extract_html() |> Sanitize.html()

        other ->
          Logger.warning("hello.Generator: shell generation failed: #{inspect(other)}")
          existing
      end
    end
  end

  # Compile the per-session CSS from BOTH the shell HTML and the body's
  # AI-authored `class` props (both invisible to the build-time Tailwind scan),
  # then store frame + css together. Recomputed each build so body styling stays
  # covered as the content changes.
  defp store_frame(session_uri, builder, shell_html, body_tree) do
    css = ShellCss.compile(shell_html <> "\n" <> body_class_markup(body_tree))
    TurnDriver.set_shell(session_uri, builder, shell_html, css)
  end

  # Throwaway markup carrying every `class` string found in the body tree, so
  # ShellCss.compile emits CSS for the AI's custom content styling too.
  defp body_class_markup(tree) do
    tree
    |> collect_classes()
    |> Enum.uniq()
    |> Enum.map(&~s(<div class="#{&1}"></div>))
    |> Enum.join("\n")
  end

  defp collect_classes(%{} = node) do
    # shadcn nodes carry custom Tailwind on `className`; legacy nodes on `class`.
    # Collect both so the per-session CSS compile generates whatever the model added.
    cls =
      case node["props"] || node[:props] do
        %{} = p -> [p["className"] || p[:className], p["class"] || p[:class]]
        _ -> []
      end

    children = List.wrap(node["children"] || node[:children] || [])

    (cls ++ Enum.flat_map(children, &collect_classes/1))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp collect_classes(list) when is_list(list), do: Enum.flat_map(list, &collect_classes/1)
  defp collect_classes(_), do: []

  defp current_shell_html(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, %{shell: s}} when is_binary(s) -> s
      _ -> ""
    end
  end

  defp current_body_tree(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, %{versions: versions, approved: approved}} when is_map(versions) ->
        case Map.get(versions, approved) do
          %{tree: tree} -> tree
          %{"tree" => tree} -> tree
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp get_title_for_shell(session_uri) do
    case current_body_tree(session_uri) do
      %{} = tree -> get_title(tree)
      _ -> "Website"
    end
  end

  # The shell owns the chrome (nav / footer / banner); drop any of those the model
  # put in the BODY so they don't render twice. Recurses through children.
  @frame_node_types ~w(nav footer banner)
  defp strip_frame_nodes(%{"children" => children} = node) when is_list(children) do
    kept =
      children
      |> Enum.reject(fn c -> is_map(c) and c["type"] in @frame_node_types end)
      |> Enum.map(&strip_frame_nodes/1)

    Map.put(node, "children", kept)
  end

  defp strip_frame_nodes(node), do: node

  # Section-level blocks are meant to be TOP-LEVEL, full-width sections. The model
  # often wrongly nests them inside a `section` (whose grid/stack layout then
  # squishes them into a cell — e.g. testimonials become 1-char strips). Hoist any
  # such block OUT of its `section` wrapper, recursively, so each renders full
  # width with its own grid intact. Sections wrapping only leaves (card/text/…)
  # are kept.
  @hoistable_blocks ~w(hero features stats testimonials logos pricing faq steps cta split banner)
  defp unwrap_sections(%{"children" => children} = node) when is_list(children) do
    new_children =
      Enum.flat_map(children, fn child ->
        child = unwrap_sections(child)

        case child do
          %{"type" => "section", "children" => kids} when is_list(kids) ->
            if Enum.any?(kids, &hoistable_block?/1), do: kids, else: [child]

          _ ->
            [child]
        end
      end)

    Map.put(node, "children", new_children)
  end

  defp unwrap_sections(node), do: node

  defp hoistable_block?(%{"type" => t}), do: t in @hoistable_blocks
  defp hoistable_block?(_), do: false

  # Shell-only path (scope == :shell): regenerate just the frame, keep the
  # existing json-render body. No page_gen, so the content is untouched.
  defp regenerate_shell_only(session_uri, builder, title, brief) do
    TurnDriver.say(
      session_uri,
      builder,
      gettext("🎨 Generating a new frame (keeping your content)…")
    )

    shell_html = ensure_shell_html(session_uri, builder, title, brief, true)

    if shell_html == "" do
      TurnDriver.say(session_uri, builder, gettext("⚠ Frame generation failed."))
      {:error, :shell_failed}
    else
      store_frame(session_uri, builder, shell_html, current_body_tree(session_uri))

      TurnDriver.say(
        session_uri,
        builder,
        gettext("✅ Frame redesigned — your content is unchanged.")
      )

      {:ok, :shell_only}
    end
  end

  # Strip markdown fences / stray prose around an HTML reply.
  defp extract_html(content) when is_binary(content) do
    content
    |> String.replace(~r/```[a-z]*/i, "")
    |> String.trim()
  end

  defp extract_html(_), do: ""

  # Backend switch: `HELLO_LLM_BACKEND=claude_code` runs the local Claude Code CLI
  # (much stronger designer); otherwise the DeepSeek HTTP API. Both return
  # `{:ok, %{content: ...}}`.
  defp call_llm(system, user_text) do
    case System.get_env("HELLO_LLM_BACKEND") do
      "claude_code" ->
        EzagentPluginHello.LLM.ClaudeCode.chat(system, user_text)

      _ ->
        case api_key() do
          key when is_binary(key) and key != "" ->
            ApiClient.chat_completion(%{
              api_url: api_url(),
              api_key: key,
              model: model(),
              messages: [
                %{role: "system", content: system},
                %{role: "user", content: user_text}
              ]
            })

          _ ->
            {:error, :no_api_key}
        end
    end
  end

  # Land the page (page-only turn — NO turn-chat) then announce completion via a
  # `say` (:session :send). Turn-composed chat does NOT push to the operator
  # LiveView in real time (it only appears on refresh); :session :send DOES. So
  # the RESULT goes through say to guarantee the operator sees completion live.
  defp land_page(session_uri, builder, spec, user_text, reframe) do
    TurnDriver.say(session_uri, builder, gettext("🛠 Rendering to the right-side preview…"))
    # The HTML frame already provides nav / footer / banner; strip any the model
    # emitted into the BODY (it doesn't always obey the prompt) so they don't
    # double up with the shell.
    spec = spec |> strip_frame_nodes() |> unwrap_sections()
    # The frame: reused when stable (body-only edit), regenerated when `reframe`
    # (scope == :both). The body's AI `class` styling is compiled into the
    # per-session CSS by `store_frame` after the body lands.
    shell_html = ensure_shell_html(session_uri, builder, get_title(spec), user_text, reframe)

    case TurnDriver.drive(session_uri, spec, "", builder) do
      {:ok, _turn} = ok ->
        store_frame(session_uri, builder, shell_html, spec)

        msg =
          if reframe do
            gettext("✅ Done! Content AND frame updated for \"%{title}\".", title: get_title(spec))
          else
            gettext("✅ Done! Content updated for \"%{title}\" (frame unchanged).",
              title: get_title(spec)
            )
          end

        TurnDriver.say(session_uri, builder, msg)
        ok

      {:error, reason} = err ->
        TurnDriver.say(
          session_uri,
          builder,
          gettext("⚠ Render failed: %{reason}", reason: inspect(reason))
        )

        err
    end
  end

  defp get_title(%{"props" => %{"title" => t}}) when is_binary(t) and t != "", do: t
  # shadcn trees have no page title — use the first Heading's text as the brand.
  defp get_title(%{} = node), do: first_heading_text(node) || gettext("Untitled")
  defp get_title(_), do: gettext("Untitled")

  defp first_heading_text(%{"type" => "Heading", "props" => %{"text" => t}})
       when is_binary(t) and t != "",
       do: t

  defp first_heading_text(%{"children" => kids}) when is_list(kids) do
    Enum.find_value(kids, &first_heading_text/1)
  end

  defp first_heading_text(_), do: nil

  # Human description of the generated page: title + per-type component counts —
  # the "what did it actually build" line.
  defp describe_page(spec) do
    types = collect_types(spec, %{})
    n = types |> Map.values() |> Enum.sum()

    parts =
      types
      |> Enum.sort_by(fn {_t, c} -> -c end)
      |> Enum.map(fn {t, c} -> "#{t}×#{c}" end)
      |> Enum.join("、")

    gettext("Page \"%{title}\" · %{n} components total (%{parts})",
      title: get_title(spec),
      n: n,
      parts: parts
    )
  end

  defp collect_types(%{} = node, acc) do
    acc =
      case Map.get(node, "type") do
        t when is_binary(t) -> Map.update(acc, t, 1, &(&1 + 1))
        _ -> acc
      end

    collect_types(Map.get(node, "children") || [], acc)
  end

  defp collect_types(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_types/2)

  defp collect_types(_other, acc), do: acc

  # The session's builder agent URI, derived from the session URI:
  # session://<ws>/hello/<name> → entity://<ws>/agent/hello_<name>
  # (matches `App.ensure_app/2`'s builder_uri).
  defp builder_uri(%URI{} = session_uri) do
    ws = Ezagent.URI.workspace_name!(session_uri)
    name = session_uri.path |> to_string() |> String.split("/", trim: true) |> List.last()
    Ezagent.URI.entity(ws, :agent, "hello_#{name}")
  end

  # Console log of the @json-render data that ACTUALLY drives the page — the
  # validated spec landed on the Surface. This is the "what changed the page"
  # record (title + node count + full JSON tree) the operator asked to see.
  defp log_spec(%URI{} = session_uri, spec) do
    {title, nodes} = describe_spec(spec)

    Logger.info(
      "hello.Generator: PAGE SPEC #{URI.to_string(session_uri)} — title=#{inspect(title)} nodes=#{nodes}\n" <>
        safe_json(spec)
    )
  end

  defp describe_spec(spec) do
    title =
      case spec do
        %{"props" => %{"title" => t}} when is_binary(t) -> t
        _ -> nil
      end

    {title, count_nodes(spec)}
  end

  # Structural node count: root + every node reachable via `children`.
  defp count_nodes(%{} = node) do
    children = Map.get(node, "children") || Map.get(node, :children) || []
    1 + count_nodes(children)
  end

  defp count_nodes(list) when is_list(list),
    do: list |> Enum.map(&count_nodes/1) |> Enum.sum()

  defp count_nodes(_), do: 0

  defp safe_json(spec) do
    case Jason.encode(spec, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(spec, limit: :infinity, pretty: true)
    end
  end

  defp api_key, do: System.get_env("HELLO_LLM_API_KEY") || System.get_env("DEEPSEEK_KEY")

  defp api_url,
    do: System.get_env("HELLO_LLM_API_URL") || "https://api.deepseek.com/chat/completions"

  defp model, do: System.get_env("HELLO_LLM_MODEL") || "deepseek-chat"
end

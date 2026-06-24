defmodule EzagentPluginHello.Generator do
  @moduledoc """
  Runs one page-generation turn for the hello builder, off the Behavior's
  GenServer process (so the slow LLM round-trip never blocks dispatch).

  `start/2` spawns a supervised Task (under `EzagentPluginHello.TaskSupervisor`);
  `generate/2` PLANS the request (`decompose/1`) and either:

    * **simple** — one LLM call → catalog page → `TurnDriver.drive/3` (Phase 0); or
    * **complex** — FANS OUT one concurrent worker per section, each building a
      catalog sub-tree, assembled into one page (`Spec.compose_page/2`) and driven
      onto the Surface (Phase 1).

  Out-of-catalog output fails closed (`Spec.validate/1`); a failed section is
  dropped and the page is composed from the survivors (single-page fallback if
  none survive), so a turn always produces something.

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

  # Per-section worker deadline — a margin over the LLM client's 60s call timeout.
  @section_timeout_ms 90_000

  @doc "Spawn a supervised Task that generates + lands a page for `user_text`."
  @spec start(URI.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def start(%URI{} = session_uri, user_text) when is_binary(user_text) do
    Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
      generate(session_uri, user_text)
    end)
  end

  @doc """
  Generate a page and land it on `session_uri`'s Surface. The orchestrator first
  PLANS (`decompose/1`): a simple request takes the single-page path; a complex
  one FANS OUT — one concurrent worker per section, each building a sub-tree,
  assembled into one page (`Spec.compose_page/2`) and driven onto the Surface.

  Worker fan-out runs as concurrent Tasks calling the same LLM path (decision:
  Phase-1 keeps workers in-process; the curl-flavor `Entity.Agent` member-worker
  fold via `add_managed_member` is a flagged follow-up — it needs a worker
  credential cascade not yet wired. The orchestrator caps for that path are
  already granted, see `App.ensure_app`).
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

    {plan, scope} = decompose(user_text)

    case scope do
      # Shell-only: keep the existing json-render BODY untouched, regenerate just
      # the HTML frame. No page_gen call, so the content the user didn't ask to
      # change stays exactly as-is.
      :shell ->
        TurnDriver.say(session_uri, builder, gettext("🎨 Plan: redesign the frame only (content unchanged)."))
        regenerate_shell_only(session_uri, builder, get_title_for_shell(session_uri))

      # Body (default) or both: run the normal content generation. `reframe?`
      # forces a fresh frame too when the user asked for "both".
      _ ->
        reframe = scope == :both
        if reframe, do: TurnDriver.say(session_uri, builder, gettext("🎨 Redesigning the site frame too…"))

        case plan do
          {:complex, %{title: title, sections: sections}} ->
            TurnDriver.say(
              session_uri,
              builder,
              gettext("🧭 Plan: page \"%{title}\" split into %{count} blocks, generating in parallel.",
                title: title,
                count: length(sections)
              )
            )

            generate_complex(session_uri, builder, title, sections, user_text, reframe)

          {:simple} ->
            TurnDriver.say(session_uri, builder, gettext("🧭 Plan: single page, direct generation."))
            generate_simple(session_uri, builder, user_text, reframe)
        end
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

      land_page(session_uri, builder, spec, reframe)
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

  # The Phase-1 fan-out path: build every section concurrently, assemble, drive.
  # Sections that fail (LLM error / out-of-catalog) are dropped; the page is built
  # from those that succeeded (in plan order). If NONE survive, fall back to the
  # single-page path so the turn still produces something.
  defp generate_complex(session_uri, builder, title, sections, user_text, reframe) do
    briefs = sections |> Enum.map(fn %{brief: b} -> "・#{b}" end) |> Enum.join("\n")

    TurnDriver.say(
      session_uri,
      builder,
      gettext("⏳ Generating %{count} blocks in parallel:\n%{briefs}",
        count: length(sections),
        briefs: briefs
      )
    )

    section_trees =
      sections
      |> Task.async_stream(
        fn %{brief: brief} -> gen_section(brief) end,
        max_concurrency: max(length(sections), 1),
        timeout: @section_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {:ok, tree}} -> tree
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    kept = length(section_trees)
    failed = length(sections) - kept

    blocks_done_msg =
      if failed > 0 do
        gettext("📦 Blocks done: %{kept}/%{total} succeeded (%{failed} failed, skipped).",
          kept: kept,
          total: length(sections),
          failed: failed
        )
      else
        gettext("📦 Blocks done: %{kept}/%{total} succeeded.",
          kept: kept,
          total: length(sections)
        )
      end

    TurnDriver.say(session_uri, builder, blocks_done_msg)

    case section_trees do
      [] ->
        Logger.warning(
          "hello.Generator: all #{length(sections)} sections failed; single-page fallback"
        )

        TurnDriver.say(
          session_uri,
          builder,
          gettext("⚠ All blocks failed; regenerating with the single-page fallback…")
        )

        generate_simple(session_uri, builder, user_text, reframe)

      trees ->
        with {:ok, page} <- Spec.compose_page(title, trees) do
          log_spec(session_uri, page)

          TurnDriver.say(
            session_uri,
            builder,
            gettext("📦 Assembled: %{desc}", desc: describe_page(page))
          )

          land_page(session_uri, builder, page, reframe)
        else
          {:error, reason} = err ->
            Logger.warning("hello.Generator: compose failed: #{inspect(reason)}")

            TurnDriver.say(
              session_uri,
              builder,
              gettext("⚠ Page assembly failed: %{reason}", reason: inspect(reason))
            )

            err
        end
    end
  end

  # One worker: build a single catalog sub-tree from a section brief.
  defp gen_section(brief) do
    with {:ok, %{content: content}} <- call_llm(Prompts.worker_section_system(), brief),
         {:ok, raw} <- Spec.extract(content),
         {:ok, node} <- Spec.validate(raw) do
      {:ok, node}
    else
      other ->
        Logger.warning("hello.Generator: section build failed: #{inspect(other)}")
        :error
    end
  end

  @doc """
  Plan a request into `{:simple}` or `{:complex, %{title, sections}}` — the
  Phase-1 orchestrator's pre-classification (decision D-1). Calls the planner LLM;
  a failed/ambiguous reply degrades to `{:simple}` so generation always proceeds.
  """
  @type plan :: {:simple} | {:complex, %{title: String.t(), sections: [map()]}}
  @type scope :: :body | :shell | :both
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

  defp classify_plan(%{"mode" => "complex"} = plan) do
    case briefs_of(plan) do
      briefs when length(briefs) >= 2 ->
        title = plan |> Map.get("title", "") |> to_string()

        sections =
          briefs
          |> Enum.with_index()
          |> Enum.map(fn {brief, i} -> %{id: "s#{i}", brief: brief} end)

        {:complex, %{title: title, sections: sections}}

      _ ->
        {:simple}
    end
  end

  defp classify_plan(_), do: {:simple}

  defp briefs_of(%{"sections" => sections}) when is_list(sections) do
    sections
    |> Enum.map(fn
      %{"brief" => b} when is_binary(b) -> String.trim(b)
      %{"title" => t} when is_binary(t) -> String.trim(t)
      _ -> nil
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp briefs_of(_), do: []

  # Return the bespoke HTML frame (shell) for this session: regenerate it (LLM)
  # when `force` (a "shell"/"both"-scoped request) or none is stored yet;
  # otherwise reuse the stored frame so ordinary content edits leave it untouched.
  defp ensure_shell_html(session_uri, builder, title, force) do
    existing = current_shell_html(session_uri)

    if not force and existing != "" do
      existing
    else
      brand = if is_binary(title) and title != "", do: title, else: "Website"

      case call_llm(Prompts.shell_gen_system(), "Brand/title: #{brand}") do
        {:ok, %{content: content}} ->
          frame = extract_html(content)
          # Second, focused call: a CSS theme for the json-render content classes
          # (.hl-*), matching THIS frame — so the whole page is one coherent design.
          # A dedicated single-output call is followed far more reliably than a
          # "also write a <style>" buried in the frame prompt.
          theme = generate_content_theme(frame)
          Sanitize.html(frame <> "\n<style>\n" <> theme <> "\n</style>\n")

        other ->
          Logger.warning("hello.Generator: shell generation failed: #{inspect(other)}")
          existing
      end
    end
  end

  # Focused content-theme call. Returns CSS rules (no <style> tag) or "" on failure.
  defp generate_content_theme(frame) when is_binary(frame) and frame != "" do
    case call_llm(Prompts.theme_gen_system(), frame) do
      {:ok, %{content: content}} -> extract_css(content)
      other ->
        Logger.warning("hello.Generator: content theme failed: #{inspect(other)}")
        ""
    end
  end

  defp generate_content_theme(_), do: ""

  # Strip markdown fences / a stray <style> tag, AND every LAYOUT/sizing property
  # — the json-render components own their layout (grid/flex/width via their
  # default classes); the theme must only restyle the LOOK. Without this the model
  # sets widths/flex/columns and squishes cards into 1-char strips.
  defp extract_css(content) when is_binary(content) do
    content
    |> String.replace(~r/```[a-z]*/i, "")
    |> String.replace(~r/<\/?style[^>]*>/i, "")
    |> strip_layout_props()
    |> String.trim()
  end

  defp extract_css(_), do: ""

  @theme_strip_props ~w(
    display position top right bottom left inset float clear z-index
    width min-width max-width height min-height max-height
    flex flex-basis flex-grow flex-shrink flex-direction flex-wrap flex-flow
    grid grid-template grid-template-columns grid-template-rows grid-template-areas
    grid-auto-flow grid-auto-columns grid-auto-rows grid-column grid-row grid-area
    gap column-gap row-gap columns column-count column-width
    place-items place-content place-self justify-content justify-items justify-self
    align-items align-content align-self order overflow overflow-x overflow-y
    white-space writing-mode
  )

  defp strip_layout_props(css) do
    Enum.reduce(@theme_strip_props, css, fn p, acc ->
      String.replace(acc, ~r/(^|[;{\s])#{Regex.escape(p)}\s*:[^;{}]*;?/i, "\\1")
    end)
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
    cls =
      case node["props"] || node[:props] do
        %{} = p -> [p["class"] || p[:class]]
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

  # Shell-only path (scope == :shell): regenerate just the frame, keep the
  # existing json-render body. No page_gen, so the content is untouched.
  defp regenerate_shell_only(session_uri, builder, title) do
    TurnDriver.say(
      session_uri,
      builder,
      gettext("🎨 Generating a new frame (keeping your content)…")
    )

    shell_html = ensure_shell_html(session_uri, builder, title, true)

    if shell_html == "" do
      TurnDriver.say(session_uri, builder, gettext("⚠ Frame generation failed."))
      {:error, :shell_failed}
    else
      store_frame(session_uri, builder, shell_html, current_body_tree(session_uri))
      TurnDriver.say(session_uri, builder, gettext("✅ Frame redesigned — your content is unchanged."))
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

  defp call_llm(system, user_text) do
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

  # Land the page (page-only turn — NO turn-chat) then announce completion via a
  # `say` (:session :send). Turn-composed chat does NOT push to the operator
  # LiveView in real time (it only appears on refresh); :session :send DOES. So
  # the RESULT goes through say to guarantee the operator sees completion live.
  defp land_page(session_uri, builder, spec, reframe) do
    TurnDriver.say(session_uri, builder, gettext("🛠 Rendering to the right-side preview…"))
    # The HTML frame already provides nav / footer / banner; strip any the model
    # emitted into the BODY (it doesn't always obey the prompt) so they don't
    # double up with the shell.
    spec = strip_frame_nodes(spec)
    # The frame: reused when stable (body-only edit), regenerated when `reframe`
    # (scope == :both). The body's AI `class` styling is compiled into the
    # per-session CSS by `store_frame` after the body lands.
    shell_html = ensure_shell_html(session_uri, builder, get_title(spec), reframe)

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
  defp get_title(_), do: gettext("Untitled")

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

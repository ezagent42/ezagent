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
    TurnDriver.say(session_uri, builder, gettext("Got it, understanding your request…"))

    # Every request regenerates the WHOLE page: one shadcn spec (the full page) +
    # a fresh CSS theme designed for it. No HTML frame, no scoped edit path.
    generate_simple(session_uri, builder, user_text, true)
  end

  defp generate_for_scope(session_uri, builder, user_text) do
    {plan, scope} = decompose(user_text)

    case scope do
      # Shell-only: keep the existing json-render BODY untouched, regenerate just
      # the HTML frame. No page_gen call, so the content the user didn't ask to
      # change stays exactly as-is.
      :shell ->
        TurnDriver.say(
          session_uri,
          builder,
          gettext("Plan: redesign the frame only (content unchanged).")
        )

        regenerate_shell_only(session_uri, builder, get_title_for_shell(session_uri), user_text)

      # Body (default) or both: run the normal content generation. `reframe?`
      # forces a fresh frame too when the user asked for "both".
      _ ->
        reframe = scope == :both

        if reframe,
          do: TurnDriver.say(session_uri, builder, gettext("Redesigning the site frame too…"))

        case plan do
          {:complex, %{title: title, sections: sections}} ->
            TurnDriver.say(
              session_uri,
              builder,
              gettext(
                "🧭 Plan: page \"%{title}\" split into %{count} blocks, generating in parallel.",
                title: title,
                count: length(sections)
              )
            )

            generate_complex(session_uri, builder, title, sections, user_text, reframe)

          {:simple} ->
            TurnDriver.say(
              session_uri,
              builder,
              gettext("🧭 Plan: single page, direct generation.")
            )

            generate_simple(session_uri, builder, user_text, reframe)
        end
    end
  end

  # The Phase-0 single-page path: one LLM call → one catalog page → Surface.
  defp generate_simple(session_uri, builder, user_text, reframe) do
    # The page is all json-render: when one already exists, EDIT it (feed the LLM
    # the current spec + apply only the change) instead of rewriting from scratch.
    # The collaborative whiteboard expects each message to TWEAK the page.
    current = current_body_tree(session_uri)
    is_edit = is_map(current)

    {result, secs} =
      with_progress(
        session_uri,
        builder,
        if(is_edit, do: gettext("Editing the page"), else: gettext("Generating the page")),
        fn -> build_spec(current, user_text, is_edit) end
      )

    case result do
      {:ok, spec, mode} ->
        log_spec(session_uri, spec)

        TurnDriver.say(session_uri, builder, mode_narration(mode))

        TurnDriver.say(
          session_uri,
          builder,
          gettext("Model done in %{s}s — %{desc}", s: secs, desc: describe_page(spec))
        )

        land_page(session_uri, builder, spec, user_text, reframe, theme_action(mode))

      {:error, reason} = err ->
        Logger.warning("hello.Generator: generation failed: #{inspect(reason)}")

        TurnDriver.say(
          session_uri,
          builder,
          gettext("Generation failed after %{s}s: %{reason}", s: secs, reason: inspect(reason))
        )

        err
    end
  end

  # Emit ONE "<label>…" line, then run the slow work inline. The client renders a
  # LIVE ticking elapsed time next to that one line (no per-tick chat spam); the
  # caller's terminal "… in Ns" line then supersedes it and stops the ticker.
  # Returns {result, elapsed_seconds}.
  defp with_progress(session_uri, builder, label, fun) do
    TurnDriver.say(session_uri, builder, gettext("%{label}…", label: label))
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {result, div(System.monotonic_time(:millisecond) - start, 1000)}
  end

  # On an EDIT, ask the model for a MINIMAL PATCH against the current spec and
  # apply it (cheap + precise — "change one button" is one op, not a new tree). A
  # patch that fails to parse/apply/validate falls back to a full context-aware
  # regeneration, so an edit never dead-ends. A FIRST generation builds the whole
  # spec from scratch.
  defp build_spec(current, user_text, true) do
    case patch_edit(current, user_text) do
      {:ok, spec, ops} ->
        {:ok, spec, {:patch, ops}}

      {:error, reason} ->
        Logger.warning("hello.Generator: patch edit failed (#{inspect(reason)}); full-regen fallback")

        case fresh_spec(gen_prompt(current, user_text)) do
          {:ok, spec} -> {:ok, spec, :fallback}
          err -> err
        end
    end
  end

  defp build_spec(_current, user_text, false) do
    case fresh_spec(user_text) do
      {:ok, spec} -> {:ok, spec, :fresh}
      err -> err
    end
  end

  # Human-visible note on HOW the page was built this turn — so the operator can
  # tell at a glance whether the edit was a cheap incremental patch (and WHICH
  # nodes it touched) or a full rebuild.
  defp mode_narration({:patch, ops}) do
    detail = ops |> Enum.map(&describe_op/1) |> Enum.join("; ")
    gettext("Incremental edit — %{n} op(s): %{detail}", n: length(ops), detail: detail)
  end

  defp mode_narration(:fallback),
    do: gettext("Patch didn't apply cleanly — regenerated the whole page instead.")

  defp mode_narration(:fresh), do: gettext("Built a fresh page.")

  defp describe_op(%{"op" => "set", "id" => id, "props" => props}) when is_map(props),
    do: "set #{id}.#{props |> Map.keys() |> Enum.join(",")}"

  defp describe_op(%{"op" => "replace", "id" => id}), do: "replace #{id}"
  defp describe_op(%{"op" => "insert", "parent" => parent}), do: "insert → #{parent}"
  defp describe_op(%{"op" => "remove", "id" => id}), do: "remove #{id}"
  defp describe_op(_), do: "op"

  defp fresh_spec(prompt_text) do
    with {:ok, %{content: content}} <- call_llm(Prompts.page_gen_system(), prompt_text),
         {:ok, raw_spec} <- Spec.extract(content),
         {:ok, spec} <- Spec.validate(raw_spec) do
      {:ok, spec}
    end
  end

  # The patch path: annotate every node with an "id", ask the model for `{"ops":
  # [...]}`, apply the ops to the annotated tree, strip the ids, validate.
  defp patch_edit(current, user_text) do
    annotated = annotate_ids(current)

    with {:ok, %{content: content}} <-
           call_llm(Prompts.edit_system(), edit_user_prompt(annotated, user_text)),
         {:ok, ops} <- extract_ops(content),
         patched = apply_ops(annotated, ops),
         stripped = strip_ids(patched),
         {:ok, spec} <- Spec.validate(stripped) do
      {:ok, spec, ops}
    end
  end

  defp edit_user_prompt(annotated, user_text) do
    """
    Current page spec (every node has an "id"):

    ```json
    #{Jason.encode!(annotated)}
    ```

    Change requested:

    #{user_text}

    Emit the MINIMAL patch (ops referencing ids) to make ONLY this change.
    """
  end

  # Parse a `{"ops": [...]}` object from the model output. Be lenient about how it
  # wrapped the JSON — ```json fences, single backticks, or stray prose — by
  # grabbing the outermost `{...}` (greedy, dotall) rather than a fence-only regex.
  defp extract_ops(content) when is_binary(content) do
    json =
      case Regex.run(~r/\{.*\}/s, content) do
        [match] -> match
        _ -> ""
      end

    case Jason.decode(json) do
      {:ok, %{"ops" => ops}} when is_list(ops) -> {:ok, ops}
      {:ok, _} -> {:error, :no_ops}
      {:error, reason} -> {:error, {:json, reason}}
    end
  end

  # --- tree patching -----------------------------------------------------

  # Assign a stable "id" ("n0", "n1", …) to every node in a fresh pre-order walk,
  # so the model + the patch ops can reference nodes unambiguously.
  defp annotate_ids(node) do
    {annotated, _next} = annotate_ids(node, 0)
    annotated
  end

  defp annotate_ids(node, n) when is_map(node) do
    {children, next} =
      node
      |> Map.get("children", [])
      |> Enum.reduce({[], n + 1}, fn child, {acc, cn} ->
        {a, cn2} = annotate_ids(child, cn)
        {[a | acc], cn2}
      end)

    {node |> Map.put("id", "n#{n}") |> Map.put("children", Enum.reverse(children)), next}
  end

  defp annotate_ids(other, n), do: {other, n}

  defp strip_ids(node) when is_map(node) do
    node = Map.delete(node, "id")

    case Map.get(node, "children") do
      children when is_list(children) -> Map.put(node, "children", Enum.map(children, &strip_ids/1))
      _ -> node
    end
  end

  defp strip_ids(other), do: other

  defp apply_ops(spec, ops), do: Enum.reduce(ops, spec, fn op, acc -> apply_op(acc, op) end)

  defp apply_op(spec, %{"op" => "set", "id" => id, "props" => props}) when is_map(props) do
    update_node(spec, id, fn node ->
      Map.update(node, "props", props, fn existing -> Map.merge(existing || %{}, props) end)
    end)
  end

  defp apply_op(spec, %{"op" => "replace", "id" => id, "node" => new_node}) when is_map(new_node) do
    update_node(spec, id, fn _node -> new_node end)
  end

  defp apply_op(spec, %{"op" => "remove", "id" => id}) when is_binary(id) do
    remove_node(spec, id)
  end

  defp apply_op(spec, %{"op" => "insert", "parent" => pid, "node" => new_node} = op)
       when is_binary(pid) and is_map(new_node) do
    index = Map.get(op, "index", -1)

    update_node(spec, pid, fn node ->
      children = Map.get(node, "children", [])
      Map.put(node, "children", insert_at(children, index, new_node))
    end)
  end

  defp apply_op(spec, _unknown), do: spec

  # Apply `fun` to the node whose "id" matches; otherwise recurse into children.
  defp update_node(node, id, fun) when is_map(node) do
    if Map.get(node, "id") == id do
      fun.(node)
    else
      case Map.get(node, "children") do
        children when is_list(children) ->
          Map.put(node, "children", Enum.map(children, &update_node(&1, id, fun)))

        _ ->
          node
      end
    end
  end

  defp update_node(other, _id, _fun), do: other

  defp remove_node(node, id) when is_map(node) do
    case Map.get(node, "children") do
      children when is_list(children) ->
        kept =
          children
          |> Enum.reject(fn c -> is_map(c) and Map.get(c, "id") == id end)
          |> Enum.map(&remove_node(&1, id))

        Map.put(node, "children", kept)

      _ ->
        node
    end
  end

  defp remove_node(other, _id), do: other

  defp insert_at(list, index, item) when is_list(list) do
    if is_integer(index) and index >= 0 and index < length(list) do
      List.insert_at(list, index, item)
    else
      list ++ [item]
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
      gettext("Generating %{count} blocks in parallel:\n%{briefs}",
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
        gettext("Blocks done: %{kept}/%{total} succeeded (%{failed} failed, skipped).",
          kept: kept,
          total: length(sections),
          failed: failed
        )
      else
        gettext("Blocks done: %{kept}/%{total} succeeded.",
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
          gettext("All blocks failed; regenerating with the single-page fallback…")
        )

        generate_simple(session_uri, builder, user_text, reframe)

      trees ->
        with {:ok, page} <- Spec.compose_page(title, trees) do
          log_spec(session_uri, page)

          TurnDriver.say(
            session_uri,
            builder,
            gettext("Assembled: %{desc}", desc: describe_page(page))
          )

          land_page(session_uri, builder, page, user_text, reframe, :generate)
        else
          {:error, reason} = err ->
            Logger.warning("hello.Generator: compose failed: #{inspect(reason)}")

            TurnDriver.say(
              session_uri,
              builder,
              gettext("Page assembly failed: %{reason}", reason: inspect(reason))
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

  # Fan-out (complex) is disabled for the shadcn era — the per-section worker
  # prompt predates shadcn and produces invalid sub-trees, so it always failed and
  # fell back anyway. One page_gen call now produces the whole (5-8 section) body.
  defp classify_plan(_), do: {:simple}

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

  # Return the bespoke HTML frame (shell) for this session: regenerate it (LLM)
  # when `force` (a "shell"/"both"-scoped request) or none is stored yet;
  # otherwise reuse the stored frame so ordinary content edits leave it untouched.
  defp ensure_shell_html(session_uri, builder, title, brief, force) do
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

  # Focused content-theme call. Returns CSS rules (no <style> tag) or "" on failure.
  defp generate_content_theme(frame) when is_binary(frame) and frame != "" do
    case call_llm(Prompts.theme_gen_system(), frame) do
      {:ok, %{content: content}} ->
        extract_css(content)

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
      gettext("Generating a new frame (keeping your content)…")
    )

    shell_html = ensure_shell_html(session_uri, builder, title, brief, true)

    if shell_html == "" do
      TurnDriver.say(session_uri, builder, gettext("Frame generation failed."))
      {:error, :shell_failed}
    else
      store_frame(session_uri, builder, shell_html, current_body_tree(session_uri))

      TurnDriver.say(
        session_uri,
        builder,
        gettext("Frame redesigned — your content is unchanged.")
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
  # The LLM user message. On a FIRST generation (no current page) it is just the
  # user's request. On a FOLLOW-UP EDIT we hand the model the CURRENT spec and ask
  # it to apply ONLY the requested change, preserving everything else — the page
  # is all json-render, so an edit need not be a full rewrite.
  defp gen_prompt(current, user_text) when is_map(current) do
    """
    You are EDITING an existing page. Its current json-render spec is:

    ```json
    #{Jason.encode!(current)}
    ```

    Apply the change below, modifying ONLY what it asks for and preserving
    everything else EXACTLY — same nodes, text, props, classNames, and order for
    anything the request does not touch:

    #{user_text}

    Return the COMPLETE updated page spec (the whole tree), not a diff or fragment.
    """
  end

  defp gen_prompt(_current, user_text), do: user_text

  defp land_page(session_uri, builder, spec, _user_text, _reframe, theme_action) do
    # The spec is the WHOLE page (all shadcn). The per-page CSS THEME is built per
    # `theme_action`: a FIRST generation designs it; a TEXT-only edit KEEPS it (fast,
    # design stays put); a STRUCTURAL edit (new / replaced elements) RE-themes — but
    # SEEDED with the current theme so the look is preserved while the NEW elements
    # get styled consistently (otherwise new json-render nodes render as unstyled
    # shadcn defaults that clash with the page).
    theme = build_theme(session_uri, builder, spec, theme_action)

    case TurnDriver.drive(session_uri, spec, "", builder) do
      {:ok, _turn} = ok ->
        # No HTML shell, and NO per-session Tailwind compile: the spec's classNames
        # are SEMANTIC HOOKS (not utilities), and shadcn's own utility classes ship
        # from the build-time customer.css scan. The per-session CSS is ONLY the
        # sanitized AI theme — a plain-CSS stylesheet that restyles the shadcn DOM.
        # nil theme ⇒ an edit ⇒ leave the existing stored theme untouched.
        if theme, do: TurnDriver.set_shell(session_uri, builder, "", theme)

        TurnDriver.say(
          session_uri,
          builder,
          gettext("Done! Page \"%{title}\" generated.", title: get_title(spec))
        )

        ok

      {:error, reason} = err ->
        TurnDriver.say(
          session_uri,
          builder,
          gettext("Render failed: %{reason}", reason: inspect(reason))
        )

        err
    end
  end

  # Focused second LLM call: given the page spec, write a PLAIN CSS theme that
  # makes THIS page beautiful. Sanitized (declarative CSS, safe on the public page).
  # How to treat the per-page theme this turn, derived from what the model did:
  #   :generate  — fresh page → design a new theme
  #   :regenerate— structural edit (insert/replace) or a full rebuild → re-theme so
  #                the new elements are styled (seeded with the current theme)
  #   :keep      — text/prop-only edit → leave the theme untouched (fast)
  defp theme_action(:fresh), do: :generate
  defp theme_action(:fallback), do: :regenerate

  defp theme_action({:patch, ops}) do
    if Enum.any?(ops, fn op -> Map.get(op, "op") in ["insert", "replace"] end),
      do: :regenerate,
      else: :keep
  end

  defp build_theme(_session_uri, _builder, _spec, :keep), do: nil

  defp build_theme(session_uri, builder, spec, :generate) do
    {theme, secs} =
      with_progress(session_uri, builder, gettext("Designing theme"), fn ->
        generate_theme(spec, nil)
      end)

    TurnDriver.say(session_uri, builder, gettext("Theme ready in %{s}s.", s: secs))
    theme
  end

  defp build_theme(session_uri, builder, spec, :regenerate) do
    base = current_theme(session_uri)

    {theme, secs} =
      with_progress(session_uri, builder, gettext("Restyling so new parts match"), fn ->
        generate_theme(spec, base)
      end)

    TurnDriver.say(session_uri, builder, gettext("Theme updated in %{s}s.", s: secs))
    theme
  end

  # The session's current per-page theme CSS (nil if none yet) — the seed that lets
  # a re-theme PRESERVE the existing design while covering new elements.
  defp current_theme(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, %{shell_css: css}} when is_binary(css) and css != "" -> css
      _ -> nil
    end
  end

  defp generate_theme(spec, base_theme) do
    case call_llm(Prompts.theme_gen_system(), theme_user_prompt(spec, base_theme)) do
      {:ok, %{content: content}} ->
        Sanitize.css(content)

      other ->
        Logger.warning("hello.Generator: theme generation failed: #{inspect(other)}")
        ""
    end
  end

  # On a re-theme we hand the model the CURRENT theme and tell it to KEEP the design
  # language, only EXTENDING coverage to every (incl. new) element — so an edit's
  # new nodes are styled in harmony, not redesigned.
  defp theme_user_prompt(spec, base) when is_binary(base) and base != "" do
    """
    Here is the page's CURRENT theme. KEEP its design language EXACTLY — same
    palette, fonts, sizing, spacing, radii, overall feel. EXTEND it so EVERY element
    in the spec below is styled consistently, INCLUDING any newly added ones. Do not
    redesign; just make sure nothing renders unstyled.

    ```css
    #{base}
    ```

    The page spec:

    #{Jason.encode!(spec)}
    """
  end

  defp theme_user_prompt(spec, _base), do: Jason.encode!(spec)

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

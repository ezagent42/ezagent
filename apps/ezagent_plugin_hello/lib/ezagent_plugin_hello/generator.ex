defmodule EzagentPluginHello.Generator do
  @moduledoc """
  Runs one page-generation turn for the hello builder, off the Behavior's
  GenServer process (so the slow LLM round-trip never blocks dispatch).

  `start/2` spawns a supervised Task (under `EzagentPluginHello.TaskSupervisor`);
  `generate/2` runs the single-page path (`generate_simple/4`): one LLM call →
  catalog page → `TurnDriver.drive/3`. Out-of-catalog output fails closed
  (`Spec.validate/1`).

  Every request regenerates the WHOLE page. `build_spec/3` PATCHES the current
  spec when one exists (minimal ops, with a full-regen fallback) or builds a
  FRESH spec otherwise; `land_page/6` drives the spec onto the Surface and then
  designs / updates the per-page CSS theme (`build_theme/5`).

  this module.
  """

  require Logger

  # User-facing builder narration goes through the plugin-owned gettext backend
  # (#91). No Han-character literals may live in this app's `lib/` — the
  # `CjkLiteralGate` arch test enforces it; the Chinese copy lives in
  # `priv/gettext/zh_CN/LC_MESSAGES/default.po`.
  use Gettext, backend: EzagentPluginHello.Gettext

  alias EzagentPluginHello.{Prompts, Sanitize, Spec, TurnDriver}

  @doc "Spawn a supervised Task that generates + lands a page for `user_text`."
  @spec start(URI.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def start(%URI{} = session_uri, user_text) when is_binary(user_text) do
    Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
      generate(session_uri, user_text)
    end)
  end

  @doc "Spawn a supervised Task that answers a visitor question as the CONCIERGE — a read-only navigation/Q&A assistant that NEVER touches the Surface."
  @spec concierge_start(URI.t(), String.t(), URI.t()) :: {:ok, pid()} | {:error, term()}
  def concierge_start(%URI{} = session_uri, user_text, %URI{} = concierge_uri)
      when is_binary(user_text) do
    Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
      concierge_answer(session_uri, user_text, concierge_uri)
    end)
  end

  @doc """
  Classify a PAGE-OWNER message as a Session action: `:rebuild`, `:answer`,
  `:share`, `:publish`, or `:delegate_to_kanban`, via one cheap LLM round-trip
  (`Prompts.route_system/0`). Fail-closed to `:rebuild` — the
  owner is here to build, and a mis-route to the builder is recoverable (it
  just regenerates), whereas losing a build request is not.
  """
  @spec classify_intent(URI.t(), String.t()) ::
          :rebuild | :answer | :share | :publish | :delegate_to_kanban
  def classify_intent(%URI{} = session_uri, user_text) when is_binary(user_text) do
    case call_llm(session_uri, Prompts.route_system(), user_text) do
      {:ok, %{content: content}} when is_binary(content) ->
        interpret_intent(content)

      other ->
        Logger.warning("hello.Generator: intent classify failed (#{inspect(other)}); → rebuild")
        :rebuild
    end
  end

  @doc """
  Interpret the router model's one-word answer. SHARE→:share, PUBLISH→:publish,
  ASK→:answer, anything else→:rebuild (fail-open to build, the owner default).
  Pure — split out so the routing policy is unit-testable without the LLM.
  """
  @spec interpret_intent(String.t()) ::
          :rebuild | :answer | :share | :publish | :delegate_to_kanban
  def interpret_intent(content) when is_binary(content) do
    up = String.upcase(content)

    cond do
      String.contains?(up, "KANBAN") -> :delegate_to_kanban
      String.contains?(up, "SHARE") -> :share
      String.contains?(up, "PUBLISH") -> :publish
      String.contains?(up, "ASK") -> :answer
      true -> :rebuild
    end
  end

  @doc """
  Answer a visitor's question grounded ONLY in the current page content, and post
  the reply as a chat message from `concierge_uri`. Read-only BY CONSTRUCTION: it
  reads the approved Surface tree + calls the LLM, but writes NOTHING back to the
  Surface — the concierge can never edit / generate / publish the page.
  """
  @spec concierge_answer(URI.t(), String.t(), URI.t()) :: :ok
  def concierge_answer(%URI{} = session_uri, user_text, %URI{} = concierge_uri)
      when is_binary(user_text) do
    Gettext.put_locale(EzagentPluginHello.Gettext, "zh_CN")
    page = current_body_tree(session_uri)

    case call_llm(session_uri, Prompts.concierge_system(), concierge_user_prompt(page, user_text)) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {say, nav} = parse_concierge(content)
        TurnDriver.say_nav(session_uri, concierge_uri, say, nav)

      other ->
        Logger.warning("hello.Generator: concierge answer failed: #{inspect(other)}")

        TurnDriver.say(
          session_uri,
          concierge_uri,
          gettext("Sorry — I can't answer that right now.")
        )
    end

    :ok
  end

  # Parse the concierge model's `{"say","nav"}` JSON (lenient — grab the outermost
  # `{...}`, which also strips any stray reasoning the backend prepends). On any
  # failure fall back to the raw text with no nav. `nav` is WHITELISTED here — the
  # viewer only ever receives a known action type + a value, never arbitrary code.
  defp parse_concierge(content) do
    json =
      case Regex.run(~r/\{.*\}/s, content) do
        [match] -> match
        _ -> ""
      end

    case Jason.decode(json) do
      {:ok, %{"say" => say} = obj} when is_binary(say) and say != "" ->
        {String.trim(say), sanitize_nav(Map.get(obj, "nav"))}

      _ ->
        {String.trim(content), nil}
    end
  end

  defp sanitize_nav(%{"type" => type, "value" => value})
       when is_binary(value) and value != "" and
              type in ["switch_tab", "scroll_to", "open_url"] do
    %{"type" => type, "value" => value}
  end

  defp sanitize_nav(_), do: nil

  defp concierge_user_prompt(page, user_text) when is_map(page) do
    """
    The website's current page content (json-render spec — answer ONLY from this;
    it includes the products, the world.cup progress data, and the team):

    ```json
    #{Jason.encode!(page)}
    ```

    Visitor's question:

    #{user_text}
    """
  end

  defp concierge_user_prompt(_page, user_text), do: user_text

  @doc """
  Generate a page and land it on `session_uri`'s Surface. Every request goes
  through the single-page path (`generate_simple/4`): a FRESH session builds the
  whole spec from scratch, a follow-up edit PATCHES the current spec (with a
  full-regen fallback). See the moduledoc.
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
        fn -> build_spec(session_uri, current, user_text, is_edit) end
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

        # G5 source 2 — structured error, no hand-written prose.
        TurnDriver.say_error(session_uri, builder, {:generation_failed, reason})

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
  defp build_spec(session_uri, current, user_text, true) do
    case patch_edit(session_uri, current, user_text) do
      {:ok, spec, ops} ->
        {:ok, spec, {:patch, ops}}

      {:error, reason} ->
        Logger.warning(
          "hello.Generator: patch edit failed (#{inspect(reason)}); full-regen fallback"
        )

        case fresh_spec(session_uri, gen_prompt(current, user_text)) do
          {:ok, spec} -> {:ok, spec, :fallback}
          err -> err
        end
    end
  end

  defp build_spec(session_uri, _current, user_text, false) do
    case fresh_spec(session_uri, user_text) do
      {:ok, spec} -> {:ok, spec, :fresh}
      err -> err
    end
  end

  # Human-visible note on HOW the page was built this turn — so the internal reader can
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

  defp fresh_spec(session_uri, prompt_text) do
    with {:ok, %{content: content}} <-
           call_llm(session_uri, Prompts.page_gen_system(), prompt_text),
         {:ok, raw_spec} <- Spec.extract(content),
         {:ok, spec} <- Spec.validate(raw_spec) do
      {:ok, spec}
    end
  end

  @doc """
  Apply a list of edit `ops` to a spec tree and return the patched (id-stripped)
  tree — the pure core of the incremental-edit path, exposed for testing. Each op
  is `%{"op" => "set"|"replace"|"insert"|"remove", ...}` referencing a node by the
  `"id"` assigned in a fresh pre-order walk. An unknown op is a no-op.
  """
  @spec apply_patch(map(), [map()]) :: map()
  def apply_patch(spec, ops) when is_map(spec) and is_list(ops) do
    spec |> annotate_ids() |> apply_ops(ops) |> strip_ids()
  end

  # The patch path: annotate every node with an "id", ask the model for `{"ops":
  # [...]}`, apply the ops to the annotated tree, strip the ids, validate.
  defp patch_edit(session_uri, current, user_text) do
    annotated = annotate_ids(current)

    with {:ok, %{content: content}} <-
           call_llm(session_uri, Prompts.edit_system(), edit_user_prompt(annotated, user_text)),
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
      children when is_list(children) ->
        Map.put(node, "children", Enum.map(children, &strip_ids/1))

      _ ->
        node
    end
  end

  defp strip_ids(other), do: other

  defp apply_ops(spec, ops), do: Enum.reduce(ops, spec, fn op, acc -> apply_op(acc, op) end)

  defp apply_op(spec, %{"op" => "set", "id" => id, "props" => props}) when is_map(props) do
    update_node(spec, id, fn node ->
      Map.update(node, "props", props, fn existing -> Map.merge(existing || %{}, props) end)
    end)
  end

  defp apply_op(spec, %{"op" => "replace", "id" => id, "node" => new_node})
       when is_map(new_node) do
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

  defp current_body_tree(session_uri) do
    case Ezagent.Kind.read(session_uri, :surface, spawn: :never) do
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

  @doc false
  def complete(session_uri, system, user_text), do: call_llm(session_uri, system, user_text)

  defp call_llm(session_uri, system, user_text) do
    case EzagentPluginHello.Members.role_uri(session_uri, "llm") do
      {:ok, llm_uri} ->
        request_id = "hello-completion-" <> Integer.to_string(System.unique_integer([:positive]))
        {:ok, _} = Registry.register(EzagentPluginHello.CompletionRegistry, request_id, [])

        result =
          Ezagent.Entity.Agent.request_completion(
            Ezagent.Entity.User.admin_uri(),
            llm_uri,
            session_uri,
            compose_prompt(system, user_text),
            request_id
          )

        await_completion(result, request_id)

      :error ->
        {:error, :no_llm_agent}
    end
  end

  defp await_completion({:ok, content}, request_id) when is_binary(content) do
    Registry.unregister(EzagentPluginHello.CompletionRegistry, request_id)
    {:ok, %{content: content}}
  end

  defp await_completion({:pending, request_id}, request_id) do
    receive do
      {:hello_completion, ^request_id, content} when is_binary(content) ->
        Registry.unregister(EzagentPluginHello.CompletionRegistry, request_id)
        {:ok, %{content: content}}
    after
      120_000 ->
        Registry.unregister(EzagentPluginHello.CompletionRegistry, request_id)
        {:error, :llm_completion_timeout}
    end
  end

  defp await_completion({:error, _} = err, request_id) do
    Registry.unregister(EzagentPluginHello.CompletionRegistry, request_id)
    err
  end

  defp await_completion(other, request_id) do
    Registry.unregister(EzagentPluginHello.CompletionRegistry, request_id)
    {:error, {:unexpected_llm_result, other}}
  end

  # The platform completion contract accepts one prompt; fold Hello's per-call
  # system prompt into the user turn. Provider and credential handling remain
  # inside the selected agent flavor.
  defp compose_prompt(system, user_text), do: system <> "\n\n" <> user_text

  # Land the page (page-only turn — NO turn-chat) then announce completion via a
  # `say` (:session :send). Turn-composed chat does NOT push to the internal
  # LiveView in real time (it only appears on refresh); :session :send DOES. So
  # the RESULT goes through say to guarantee the internal reader sees completion live.
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

  defp land_page(session_uri, builder, spec, user_text, _reframe, theme_action) do
    # The spec is the WHOLE page (all shadcn). The per-page CSS THEME is built per
    # `theme_action`: a FIRST generation designs it; a TEXT-only edit KEEPS it (fast,
    # design stays put); a STRUCTURAL edit (new / replaced elements) RE-themes — but
    # SEEDED with the current theme so the look is preserved while the NEW elements
    # get styled consistently (otherwise new json-render nodes render as unstyled
    # shadcn defaults that clash with the page).
    # An explicit APPEARANCE request (make it cooler / change the colors / …)
    # RE-themes with that instruction — the look lives in the THEME (CSS), not the
    # spec, so a spec patch alone can only change text/structure, never the style.
    action = if style_request?(user_text), do: :restyle, else: theme_action
    theme = build_theme(session_uri, builder, spec, action, user_text)

    case TurnDriver.drive(session_uri, spec, "", builder) do
      {:ok, _turn} = ok ->
        # No HTML shell, and NO per-session Tailwind compile: the spec's classNames
        # are SEMANTIC HOOKS (not utilities), and shadcn's own utility classes ship
        # from the build-time viewer.css scan. The per-session CSS is ONLY the
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
        # G5 source 2 — structured error, no hand-written prose.
        TurnDriver.say_error(session_uri, builder, {:render_failed, reason})

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

  defp build_theme(_session_uri, _builder, _spec, :keep, _user_text), do: nil

  defp build_theme(session_uri, builder, spec, :generate, _user_text) do
    {theme, secs} =
      with_progress(session_uri, builder, gettext("Designing theme"), fn ->
        generate_theme(session_uri, spec, nil, nil)
      end)

    TurnDriver.say(session_uri, builder, gettext("Theme ready in %{s}s.", s: secs))
    theme
  end

  defp build_theme(session_uri, builder, spec, :regenerate, _user_text) do
    base = current_theme(session_uri)

    {theme, secs} =
      with_progress(session_uri, builder, gettext("Restyling so new parts match"), fn ->
        generate_theme(session_uri, spec, base, nil)
      end)

    TurnDriver.say(session_uri, builder, gettext("Theme updated in %{s}s.", s: secs))
    theme
  end

  # An APPEARANCE request restyles the theme WITH the user's instruction (seeded
  # with the current theme so unrelated parts stay coherent).
  defp build_theme(session_uri, builder, spec, :restyle, user_text) do
    base = current_theme(session_uri)

    {theme, secs} =
      with_progress(session_uri, builder, gettext("Restyling the look"), fn ->
        generate_theme(session_uri, spec, base, user_text)
      end)

    TurnDriver.say(session_uri, builder, gettext("Restyled in %{s}s.", s: secs))
    theme
  end

  # Appearance/style intent → route to the theme step. Heuristic; a false positive
  # just costs an extra re-theme, never a wrong edit. The keyword list (incl.
  # Chinese terms) lives in `priv/style_keywords.txt`, NOT inline — the
  # CjkLiteralGate forbids Han literals in lib/*.ex, and a data file keeps the copy
  # out of source. Matched case-insensitively as a plain substring contains.
  defp style_request?(text) when is_binary(text) do
    down = String.downcase(text)
    Enum.any?(style_keywords(), fn kw -> String.contains?(down, kw) end)
  end

  defp style_request?(_), do: false

  defp style_keywords do
    path = Path.join(:code.priv_dir(:ezagent_plugin_hello), "style_keywords.txt")

    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  # The session's current per-page theme CSS (nil if none yet) — the seed that lets
  # a re-theme PRESERVE the existing design while covering new elements.
  defp current_theme(session_uri) do
    case Ezagent.Kind.read(session_uri, :surface, spawn: :never) do
      {:ok, %{shell_css: css}} when is_binary(css) and css != "" -> css
      _ -> nil
    end
  end

  defp generate_theme(session_uri, spec, base_theme, instruction) do
    case call_llm(
           session_uri,
           Prompts.theme_gen_system(),
           theme_user_prompt(spec, base_theme, instruction)
         ) do
      {:ok, %{content: content}} ->
        Sanitize.css(content)

      other ->
        Logger.warning("hello.Generator: theme generation failed: #{inspect(other)}")
        ""
    end
  end

  # Build the theme-model user message: an optional STYLE instruction (an
  # appearance edit), the optional CURRENT theme to preserve + extend, then the
  # spec. With an instruction the model restyles the asked-for element; without
  # one it keeps the design and just covers every (incl. new) element.
  defp theme_user_prompt(spec, base, instruction) do
    instr_part =
      if is_binary(instruction) and String.trim(instruction) != "" do
        """
        STYLE CHANGE the user asked for — APPLY it. Restyle the relevant element /
        section with Ezagent DS language (cobalt actions, solid red/yellow/jade
        accents, pill controls, white floating cards, soft shadows, strong type and
        spacing; avoid decorative gradient fills), keeping the rest coherent:

        #{instruction}

        """
      else
        ""
      end

    base_part =
      if is_binary(base) and base != "" do
        """
        The page's CURRENT theme — KEEP its design language (palette, fonts, spacing,
        radii) EXCEPT where the change above asks otherwise, and EXTEND it so EVERY
        element in the spec (including any newly added ones) is styled, nothing bare:

        ```css
        #{base}
        ```

        """
      else
        ""
      end

    instr_part <> base_part <> "The page spec:\n\n#{Jason.encode!(spec)}"
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

  # Generated-page narration is emitted by the session's front-desk agent. The
  # builder is a Session action, not an independently materialized member.
  defp builder_uri(%URI{} = session_uri) do
    case EzagentPluginHello.Members.role_uri(session_uri, "front-desk") do
      {:ok, uri} -> uri
      :error -> legacy_builder_uri(session_uri)
    end
  end

  defp legacy_builder_uri(%URI{} = session_uri) do
    ws = Ezagent.URI.workspace_name!(session_uri)

    name =
      session_uri
      |> Map.get(:path, "")
      |> to_string()
      |> String.split("/", trim: true)
      |> List.last()

    Ezagent.URI.entity(ws, :agent, "hello_#{name}")
  end

  # Console log of the @json-render data that ACTUALLY drives the page — the
  # validated spec landed on the Surface. This is the "what changed the page"
  # record (title + node count + full JSON tree) the internal reader asked to see.
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

  # === card path (chat-bubble json-render fragment) =====================

  @doc """
  Producer-free render-card tool: turn a "show me the data" request into a
  json-render card FRAGMENT (+ optional css) for a chat bubble. Returns
  `{:ok, %{spec: tree, css: css | nil}}`. The producer posts it as a message
  whose `body` carries `render: spec` (+ `render_css: css`); the render transport
  (`feed_encoding`, #1035) shows it as a card. NO persona/cap coupling — any
  producer can call it. `current` is the current page spec (or nil) so the model
  can reuse on-page data/components. Retried once on malformed JSON.
  """
  @spec render_card(URI.t(), map() | nil, String.t()) ::
          {:ok, %{spec: map(), css: String.t() | nil}} | {:error, term()}
  def render_card(%URI{} = session_uri, current, user_text) when is_binary(user_text) do
    with {:ok, spec} <- card_spec_with_retry(session_uri, current, user_text) do
      css = if style_request?(user_text), do: card_css(session_uri, spec, user_text), else: nil
      {:ok, %{spec: spec, css: css}}
    end
  end

  defp card_spec_with_retry(session_uri, current, user_text) do
    case card_spec(session_uri, current, user_text) do
      {:ok, _} = ok -> ok
      {:error, _} -> card_spec(session_uri, current, user_text)
    end
  end

  # Ask the model for ONE catalog fragment (root = Card/Stack/Table…), validate it
  # against the same catalog as a page. `current` page spec (if any) is context.
  defp card_spec(session_uri, current, user_text) do
    prompt =
      if is_map(current) do
        """
        The page's CURRENT spec (reuse its data/components where relevant):

        ```json
        #{Jason.encode!(current)}
        ```

        Show the user this, as a self-contained card/table fragment:

        #{user_text}
        """
      else
        user_text
      end

    with {:ok, %{content: content}} <- call_llm(session_uri, Prompts.card_gen_system(), prompt),
         {:ok, raw} <- Spec.extract(content),
         {:ok, spec} <- Spec.validate(raw) do
      {:ok, spec}
    end
  end

  # Per-card CSS theme — only when the user explicitly asks for a look. The model
  # writes un-prefixed selectors; the client scopes them to the card's unique id.
  # Returns nil on failure (default styling) rather than a broken theme.
  defp card_css(session_uri, spec, user_text) do
    prompt = """
    Style request: #{user_text}

    The card spec:

    #{Jason.encode!(spec)}
    """

    case call_llm(session_uri, Prompts.card_theme_system(), prompt) do
      {:ok, %{content: content}} ->
        case Sanitize.css(content) do
          css when is_binary(css) and css != "" -> css
          _ -> nil
        end

      other ->
        Logger.warning("hello.Generator: card theme failed: #{inspect(other)}")
        nil
    end
  end
end

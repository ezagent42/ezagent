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

  alias EzagentPluginHello.{Prompts, Spec, TurnDriver}
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
    builder = builder_uri(session_uri)
    # First-moment acknowledgement (before the slow planner LLM call).
    TurnDriver.say(session_uri, builder, "收到 ✅ 正在理解你的需求…")

    case decompose(user_text) do
      {:complex, %{title: title, sections: sections}} ->
        TurnDriver.say(
          session_uri,
          builder,
          "🧭 规划:页面「#{title}」拆成 #{length(sections)} 个区块,并行生成。"
        )

        generate_complex(session_uri, builder, title, sections, user_text)

      {:simple} ->
        TurnDriver.say(session_uri, builder, "🧭 规划:单页直接生成。")
        generate_simple(session_uri, builder, user_text)
    end
  end

  # The Phase-0 single-page path: one LLM call → one catalog page → Surface.
  defp generate_simple(session_uri, builder, user_text) do
    TurnDriver.say(session_uri, builder, "🧠 正在调用模型生成页面…")

    with {:ok, %{content: content}} <- call_llm(Prompts.page_gen_system(), user_text),
         {:ok, raw_spec} <- Spec.extract(content),
         {:ok, spec} <- Spec.validate(raw_spec) do
      log_spec(session_uri, spec)
      TurnDriver.say(session_uri, builder, "📦 已生成结构:#{describe_page(spec)}")
      land_page(session_uri, builder, spec)
    else
      {:error, reason} = err ->
        Logger.warning("hello.Generator: generation failed: #{inspect(reason)}")
        TurnDriver.say(session_uri, builder, "⚠ 生成失败:#{inspect(reason)}")
        err
    end
  end

  # The Phase-1 fan-out path: build every section concurrently, assemble, drive.
  # Sections that fail (LLM error / out-of-catalog) are dropped; the page is built
  # from those that succeeded (in plan order). If NONE survive, fall back to the
  # single-page path so the turn still produces something.
  defp generate_complex(session_uri, builder, title, sections, user_text) do
    briefs = sections |> Enum.map(fn %{brief: b} -> "・#{b}" end) |> Enum.join("\n")
    TurnDriver.say(session_uri, builder, "⏳ 并行生成 #{length(sections)} 个区块:\n#{briefs}")

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

    TurnDriver.say(
      session_uri,
      builder,
      "📦 区块完成:#{kept}/#{length(sections)} 成功" <>
        if(failed > 0, do: "(#{failed} 个失败已跳过)", else: "") <> "。"
    )

    case section_trees do
      [] ->
        Logger.warning(
          "hello.Generator: all #{length(sections)} sections failed; single-page fallback"
        )

        TurnDriver.say(session_uri, builder, "⚠ 全部区块失败,改用单页兜底重新生成…")
        generate_simple(session_uri, builder, user_text)

      trees ->
        with {:ok, page} <- Spec.compose_page(title, trees) do
          log_spec(session_uri, page)
          TurnDriver.say(session_uri, builder, "📦 已组装:#{describe_page(page)}")
          land_page(session_uri, builder, page)
        else
          {:error, reason} = err ->
            Logger.warning("hello.Generator: compose failed: #{inspect(reason)}")
            TurnDriver.say(session_uri, builder, "⚠ 组装页面失败:#{inspect(reason)}")
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
  @spec decompose(String.t()) :: {:simple} | {:complex, %{title: String.t(), sections: [map()]}}
  def decompose(user_text) when is_binary(user_text) do
    case call_llm(Prompts.decompose_system(), user_text) do
      {:ok, %{content: content}} -> parse_plan(content)
      {:error, _} -> {:simple}
    end
  end

  @doc """
  Parse the planner's reply into a plan. Pure. Anything that is not an explicit,
  well-formed `complex` plan with ≥2 usable section briefs degrades to `{:simple}`
  (the hard floor — fan-out is opt-in, only when it clearly pays off). Section ids
  are assigned deterministically (`"s0"`, `"s1"`, …), NEVER taken from the LLM, so
  no untrusted strings become turn subtask keys.
  """
  @spec parse_plan(term()) :: {:simple} | {:complex, %{title: String.t(), sections: [map()]}}
  def parse_plan(content) when is_binary(content) do
    case Spec.extract(content) do
      {:ok, %{"mode" => "complex"} = plan} ->
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

      _ ->
        {:simple}
    end
  end

  def parse_plan(_), do: {:simple}

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
  defp land_page(session_uri, builder, spec) do
    TurnDriver.say(session_uri, builder, "🛠 正在渲染到右侧预览…")

    case TurnDriver.drive(session_uri, spec, "", builder) do
      {:ok, _turn} = ok ->
        TurnDriver.say(
          session_uri,
          builder,
          "✅ 完成!页面「#{get_title(spec)}」已渲染到右侧预览。"
        )

        ok

      {:error, reason} = err ->
        TurnDriver.say(session_uri, builder, "⚠ 渲染失败:#{inspect(reason)}")
        err
    end
  end

  defp get_title(%{"props" => %{"title" => t}}) when is_binary(t) and t != "", do: t
  defp get_title(_), do: "未命名"

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

    "页面「#{get_title(spec)}」· 共 #{n} 个组件(#{parts})"
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
  defp builder_uri(%URI{host: ws} = session_uri) do
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

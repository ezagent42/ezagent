defmodule Ezagent.PluginLoom.WorkerConfig do
  @moduledoc """
  Loom **per-session worker 配置**(2026-06-15)。

  每个 loom session 可以配置自己的一组业务 worker —— 取代以前"所有 session 都硬塞
  policy / company 两个 worker"的做法。配置是这组 worker 的**真相源**:

      %{ "session://loom/<ws>/<sid>" =>
           [ %{"key" => "worker1", "desc" => "通用助手 A", "prompt" => "..."},
             %{"key" => "painter",  "desc" => "视觉/配图",  "prompt" => "..."} ] }

  - `key`  — slug(`^[a-z][a-z0-9_]*$`),映射 `entity://agent/<ws>/loomworker_<sid>_<key>`。
  - `desc` — 一句话职责,**给编排器路由用**(写进 worker 的 `:loom_worker` slice `role`,
    `LoomOrchestrator.worker_hint/1` 据此提示模型派谁)。
  - `prompt` — worker 的系统提示词(写进 slice `system_prompt`,决定它干活的行为)。

  旁路 JSON(仿 Stats / Materials):`~/.ezagent/<profile>/loom_workers.json`。

  ## 真相源 vs 活成员

  - **新建 session**:`Team.ensure_team` 调 `get_or_seed/2`,首次落地 2 个通用 worker 默认值。
  - **老 session(zuatu 等,启动时显式带 policy/company)**:配置文件里没有 → `get_for_session/1`
    第一次读时**从活成员导入**(扫 `loomworker_<sid>_*` 的 slice),让 UI 看到现有 worker 并可编辑。
  - 改配置(增 / 改 / 删)→ 同步把活团队 reconcile 成配置的样子(spawn+join / 换 prompt / leave+terminate)。

  join / leave / spawn / terminate 走的都是 `Team.ensure_team` / `LoomMetaAgent` 用的同一套
  底层原语(`system://session-internal` 主体 + `Ezagent.Kind.spawn` / `terminate`),无新 action / caps。
  """

  require Logger

  alias Ezagent.Invocation

  @key_re ~r/^[a-z][a-z0-9_]*$/
  @max_workers 12
  @max_desc 120
  @max_prompt 6000

  # ── store ──

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_workers.json")
  end

  defp load_all do
    case File.read(file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_all(map) when is_map(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
  end

  defp skey(ws, sid), do: "session://loom/#{ws}/#{sid}"

  # ── orchestrator instruction store (separate sidecar) ──
  # per-session 自由文本,注入 loomorch 的 decompose / compose / direct-answer 提示词。
  # 不碰 orchestrator 的 slice(它持有 loom_source),loomorch 每轮读这个文件。

  @max_orch 8000

  defp orch_file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_orchestrator.json")
  end

  defp load_orch do
    case File.read(orch_file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc "读某 session 的编排器自定义指令(无 → 空串)。"
  @spec get_orchestrator(String.t(), String.t()) :: String.t()
  def get_orchestrator(ws, sid) when is_binary(ws) and is_binary(sid) do
    Map.get(load_orch(), skey(ws, sid), "") |> to_string()
  rescue
    _ -> ""
  end

  def get_orchestrator(_, _), do: ""

  @doc "写某 session 的编排器自定义指令(截断到上限)。"
  @spec put_orchestrator(String.t(), String.t(), String.t()) :: :ok
  def put_orchestrator(ws, sid, text) when is_binary(ws) and is_binary(sid) and is_binary(text) do
    text = String.slice(text, 0, @max_orch)
    path = orch_file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, load_orch() |> Map.put(skey(ws, sid), text) |> Jason.encode!(pretty: true))
    :ok
  rescue
    _ -> :ok
  end

  def put_orchestrator(_, _, _), do: :ok

  # ── stitch 接待模式(stitch | human)──
  # human:Stitch 不自动答访客,改出一段给运营看的分析(见 LoomStitchWorker)。

  defp stitch_mode_file do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_stitch_mode.json")
  end

  @doc "读 stitch 接待模式(默认 stitch)。"
  @spec get_stitch_mode(String.t(), String.t()) :: String.t()
  def get_stitch_mode(ws, sid) when is_binary(ws) and is_binary(sid) do
    case File.read(stitch_mode_file()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) ->
            if Map.get(m, skey(ws, sid)) == "human", do: "human", else: "stitch"

          _ ->
            "stitch"
        end

      _ ->
        "stitch"
    end
  rescue
    _ -> "stitch"
  end

  def get_stitch_mode(_, _), do: "stitch"

  @doc "写 stitch 接待模式(只接受 stitch | human)。"
  @spec put_stitch_mode(String.t(), String.t(), String.t()) :: :ok
  def put_stitch_mode(ws, sid, mode) when is_binary(ws) and is_binary(sid) do
    mode = if mode == "human", do: "human", else: "stitch"
    path = stitch_mode_file()

    all =
      case File.read(path) do
        {:ok, b} ->
          case Jason.decode(b) do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end

        _ ->
          %{}
      end

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, all |> Map.put(skey(ws, sid), mode) |> Jason.encode!(pretty: true))
    :ok
  rescue
    _ -> :ok
  end

  def put_stitch_mode(_, _, _), do: :ok

  @doc "新建 session 的默认 worker(2 个通用,可在 UI 改 / 删)。"
  def default_workers do
    [
      %{"key" => "worker1", "desc" => "通用助手 A", "prompt" => generic_prompt("助手 A")},
      %{"key" => "worker2", "desc" => "通用助手 B", "prompt" => generic_prompt("助手 B")}
    ]
  end

  defp generic_prompt(label) do
    "你是 Loom 编排团队里的一名通用 worker(#{label})。编排器会把一个子任务交给你," <>
      "你只产出该子任务对应的**一段内容片段**:中文、简洁、具体、可读,可合理虚构细节使其逼真。" <>
      "不要寒暄,不要输出卡片或 JSON,只回正文片段。编排器会把多名 worker 的片段组合后再回给用户。"
  end

  @doc "配置文件里存的(无 → nil,区别于\"空配置\")。"
  @spec stored(String.t(), String.t()) :: [map()] | nil
  def stored(ws, sid) do
    case Map.get(load_all(), skey(ws, sid)) do
      list when is_list(list) -> list
      _ -> nil
    end
  end

  @doc "给 Team.ensure_team 用:有存的就用,没有就落地默认 2 个通用 worker 并返回。"
  @spec get_or_seed(String.t(), String.t()) :: [map()]
  def get_or_seed(ws, sid) do
    case stored(ws, sid) do
      nil ->
        put_list(ws, sid, default_workers())
        default_workers()

      list ->
        list
    end
  end

  @doc """
  给 UI(GET /workers)用:有存的就用;没存过但活团队里已有 worker(老 session,如 zuatu
  的 policy/company)→ 从活成员导入并落地;都没有 → 落地默认 2 个通用 worker。
  """
  @spec get_for_session(URI.t()) :: [map()]
  def get_for_session(%URI{} = session_uri) do
    with {:ok, ws, sid} <- parts(session_uri) do
      case stored(ws, sid) do
        list when is_list(list) ->
          list

        nil ->
          imported = import_from_live(session_uri, sid)

          cond do
            imported != [] -> put_list(ws, sid, imported)
            true -> get_or_seed(ws, sid)
          end
      end
    else
      _ -> []
    end
  end

  def get_for_session(_), do: []

  defp put_list(ws, sid, list) when is_list(list) do
    all = load_all()
    all |> Map.put(skey(ws, sid), list) |> save_all()
    list
  rescue
    _ -> list
  end

  # ── mutate + reconcile ──

  @doc """
  增 / 改一个 worker(upsert by key),持久化,并把这个 worker reconcile 进活团队
  (新增 → spawn+join;改 → terminate 旧的换 prompt 再 spawn+join)。返回新配置列表。
  """
  @spec upsert(URI.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def upsert(%URI{} = session_uri, %{} = raw) do
    with {:ok, ws, sid} <- parts(session_uri),
         {:ok, w} <- validate(raw) do
      base = get_for_session(session_uri)

      if length(base) >= @max_workers and not Enum.any?(base, &(&1["key"] == w["key"])) do
        {:error, :too_many_workers}
      else
        next = base |> Enum.reject(&(&1["key"] == w["key"])) |> Kernel.++([w])
        put_list(ws, sid, next)
        _ = apply_add_or_edit(session_uri, ws, sid, w)
        {:ok, next}
      end
    end
  end

  @doc "删一个 worker(by key),持久化,并从活团队 leave + terminate。返回新配置列表。"
  @spec remove(URI.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def remove(%URI{} = session_uri, key) when is_binary(key) do
    with {:ok, ws, sid} <- parts(session_uri) do
      base = get_for_session(session_uri)
      next = Enum.reject(base, &(&1["key"] == key))
      put_list(ws, sid, next)
      _ = apply_remove(session_uri, ws, sid, key)
      {:ok, next}
    end
  end

  @doc """
  把活团队 reconcile 成配置的样子:配置里每个 worker 确保 spawn+join(幂等,不换已在的
  prompt);活着的 `loomworker_<sid>_*` 不在配置里的 → leave + terminate。
  老 session boot(没重跑 ensure_team)时按需用。
  """
  @spec reconcile(URI.t()) :: :ok
  def reconcile(%URI{} = session_uri) do
    with {:ok, ws, sid} <- parts(session_uri) do
      desired = get_for_session(session_uri)
      desired_keys = Enum.map(desired, & &1["key"])

      Enum.each(desired, fn w -> ensure_present(session_uri, ws, sid, w) end)

      session_uri
      |> live_worker_keys(sid)
      |> Enum.reject(&(&1 in desired_keys))
      |> Enum.each(fn orphan -> apply_remove(session_uri, ws, sid, orphan) end)

      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # ── live-team primitives (mirror Team.ensure_team / LoomMetaAgent) ──

  defp apply_add_or_edit(session_uri, ws, sid, %{"key" => key} = w) do
    uri = worker_uri(ws, sid, key)

    # terminate-first 保证改 prompt 时拿到全新 slice(spawn 对 already_started 是幂等的,
    # 不会覆盖旧 slice)。新增时 terminate 是 no-op。
    _ = Ezagent.Kind.terminate(uri)
    _ = spawn_with_config(uri, w)
    _ = join(session_uri, uri)
    :ok
  end

  # 只在不在时 spawn(不 terminate,避免 reconcile 把在跑的 worker 重启掉 state)。
  defp ensure_present(session_uri, ws, sid, %{"key" => key} = w) do
    uri = worker_uri(ws, sid, key)
    _ = spawn_with_config(uri, w)
    _ = join(session_uri, uri)
    :ok
  end

  defp apply_remove(session_uri, ws, sid, key) do
    uri = worker_uri(ws, sid, key)
    _ = leave(session_uri, uri)
    _ = Ezagent.Kind.terminate(uri)
    :ok
  end

  defp spawn_with_config(uri, %{"desc" => desc, "prompt" => prompt}) do
    case Ezagent.Kind.spawn(Ezagent.Entity.LoomWorker, %{
           uri: uri,
           role: desc,
           system_prompt: prompt
         }) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning("WorkerConfig: spawn #{URI.to_string(uri)} → #{inspect(reason)}")
    end
  end

  defp join(session_uri, member_uri),
    do: dispatch_membership(session_uri, member_uri, :join)

  defp leave(session_uri, member_uri),
    do: dispatch_membership(session_uri, member_uri, :leave)

  defp dispatch_membership(session_uri, member_uri, action) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.#{action}")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :cast,
      args: %{member: member_uri},
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri("session-internal"),
        caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
        reply: :ignore
      }
    })

    :ok
  rescue
    _ -> :ok
  end

  # ── live-team reads ──

  # 扫 chat.members 找 `loomworker_<sid>_<key>` 的 key 列表。
  defp live_worker_keys(session_uri, sid) do
    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, %{members: members}} when is_map(members) ->
        prefix = "loomworker_#{sid}_"

        members
        |> Map.keys()
        |> Enum.flat_map(fn uri -> worker_key_of(uri, prefix) end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # 没配置但活团队里已有 worker(老 session)→ 从 slice 读 role/system_prompt 导入。
  defp import_from_live(session_uri, sid) do
    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, %{members: members}} when is_map(members) ->
        prefix = "loomworker_#{sid}_"

        members
        |> Map.keys()
        |> Enum.flat_map(fn uri ->
          case worker_key_of(uri, prefix) do
            [key] -> [worker_from_slice(uri, key)]
            _ -> []
          end
        end)
        |> Enum.sort_by(& &1["key"])

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp worker_from_slice(%URI{} = uri, key) do
    {desc, prompt} =
      case Ezagent.Kind.get_slice(uri, :loom_worker) do
        {:ok, slice} ->
          {to_string(Map.get(slice, :role) || Map.get(slice, "role") || key),
           to_string(Map.get(slice, :system_prompt) || Map.get(slice, "system_prompt") || "")}

        _ ->
          {key, ""}
      end

    %{"key" => key, "desc" => desc, "prompt" => prompt}
  end

  defp worker_key_of(uri, prefix) do
    case uri do
      %URI{path: "/" <> rest} ->
        case String.split(rest, "/") do
          [_ws, name] ->
            if String.starts_with?(name, prefix),
              do: [String.replace_prefix(name, prefix, "")],
              else: []

          _ ->
            []
        end

      s when is_binary(s) ->
        case URI.new(s) do
          {:ok, u} -> worker_key_of(u, prefix)
          _ -> []
        end

      _ ->
        []
    end
  end

  # ── helpers ──

  defp worker_uri(ws, sid, key),
    do: Ezagent.URI.new!("entity://agent/#{ws}/loomworker_#{sid}_#{key}")

  defp validate(raw) do
    key = raw |> Map.get("key", Map.get(raw, :key, "")) |> to_string() |> String.trim()
    desc = raw |> Map.get("desc", Map.get(raw, :desc, "")) |> to_string() |> String.trim()
    prompt = raw |> Map.get("prompt", Map.get(raw, :prompt, "")) |> to_string()

    cond do
      not Regex.match?(@key_re, key) ->
        {:error, :invalid_key}

      byte_size(desc) > @max_desc ->
        {:error, :desc_too_long}

      byte_size(prompt) > @max_prompt ->
        {:error, :prompt_too_long}

      true ->
        {:ok,
         %{
           "key" => key,
           "desc" => if(desc == "", do: key, else: desc),
           "prompt" => prompt
         }}
    end
  end

  defp parts(%URI{scheme: "session", path: path}) when is_binary(path) do
    case path |> String.trim_leading("/") |> String.split("/") do
      [ws, sid | _] when ws != "" and sid != "" -> {:ok, ws, sid}
      _ -> {:error, :bad_session_uri}
    end
  end

  defp parts(_), do: {:error, :bad_session_uri}
end

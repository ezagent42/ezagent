defmodule Ezagent.PluginLoom.RoleConfig do
  @moduledoc """
  Loom **per-session 角色配置**(2026-06-16,v2 自定义角色)。

  给发布物加「按登录身份解锁的隐藏入口」。角色**由作者自定义**(不是固定的几种),
  每个角色配:
  - `key`   — `?role=<key>` 的值(slug)。
  - `label` — 按钮文本。
  - `effect`— 点按钮的效果:`"navigate"`(幕跳转到某隐藏视图)或 `"link"`(新标签打开 URL)。
  - `view`  — effect=navigate 时的目标视图名(builder 在页面里建好)。
  - `url`   — effect=link 时的目标链接。
  - `entities` — 哪些登录账号属于这个角色(entity URI 列表)。

  发布页带 `?role=<key>` 时(此时 `?intent=` 不生效,任何 role 都看首页),salesperson 输入框
  右侧按 cookie 身份核对出现按钮。

  旁路 JSON:`~/.ezagent/<profile>/loom_roles.json`,key = session 字符串 →

      %{ "roles" => [ %{"key","label","effect","view","url","entities"}, ... ] }
  """

  @key_re ~r/^[a-z0-9][a-z0-9_-]*$/
  @effects ~w(navigate link)
  @max_roles 24
  @max_entities 50

  # ── store ──

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_roles.json")
  end

  defp skey(ws, sid), do: "session://loom/#{ws}/#{sid}"

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

  defp save_all(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
  end

  @doc "读某 session 的角色列表(无 → 空列表)。"
  @spec get(String.t(), String.t()) :: %{String.t() => list()}
  def get(ws, sid) when is_binary(ws) and is_binary(sid) do
    case Map.get(load_all(), skey(ws, sid)) do
      %{"roles" => list} when is_list(list) -> %{"roles" => Enum.map(list, &norm_role/1)}
      _ -> %{"roles" => []}
    end
  rescue
    _ -> %{"roles" => []}
  end

  def get(_, _), do: %{"roles" => []}

  defp norm_role(r) when is_map(r) do
    %{
      "key" => r |> Map.get("key", "") |> to_string(),
      "label" => r |> Map.get("label", "") |> to_string(),
      "effect" => effect_of(Map.get(r, "effect")),
      "view" => r |> Map.get("view", "") |> to_string(),
      "url" => r |> Map.get("url", "") |> to_string(),
      "entities" => entities_of(r)
    }
  end

  defp norm_role(_), do: nil

  defp effect_of(e) when e in @effects, do: e
  defp effect_of(_), do: "navigate"

  defp entities_of(%{"entities" => list}) when is_list(list),
    do:
      list
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 != ""))
      |> Enum.uniq()
      |> Enum.take(@max_entities)

  defp entities_of(_), do: []

  @doc """
  整盘写某 session 的角色列表。校验 key(slug,去重)+ effect;`ws` 给定时把 entities 里
  非完整 `entity://` 的补成 `entity://user/<ws>/<x>`。返回规范化后的 `%{"roles"=>[...]}`。
  """
  @spec put(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(ws, sid, config) when is_binary(ws) and is_binary(sid) and is_map(config) do
    incoming = Map.get(config, "roles", [])
    incoming = if is_list(incoming), do: incoming, else: []

    roles =
      incoming
      |> Enum.map(&norm_role/1)
      |> Enum.filter(&(is_map(&1) and Regex.match?(@key_re, &1["key"])))
      |> Enum.uniq_by(& &1["key"])
      |> Enum.take(@max_roles)
      |> Enum.map(fn r ->
        Map.update!(r, "entities", fn es -> Enum.map(es, &canonical_entity(&1, ws)) end)
      end)

    all = load_all() |> Map.put(skey(ws, sid), %{"roles" => roles})
    save_all(all)
    {:ok, %{"roles" => roles}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def put(_, _, _), do: {:error, :bad_args}

  @doc """
  核对 `entity_uri` 是否属于 key=`role` 的角色。返回 `{granted?, role_map | nil}`
  (role_map = %{"label","effect","view","url"})。
  """
  @spec check(String.t(), String.t(), String.t(), String.t() | nil) :: {boolean(), map() | nil}
  def check(ws, sid, role, entity_uri) when is_binary(role) and role != "" do
    %{"roles" => roles} = get(ws, sid)

    case Enum.find(roles, &(&1["key"] == role)) do
      nil ->
        {false, nil}

      r ->
        granted =
          is_binary(entity_uri) and entity_uri != "" and entity_uri in (r["entities"] || [])

        {granted, Map.take(r, ["label", "effect", "view", "url"])}
    end
  rescue
    _ -> {false, nil}
  end

  def check(_, _, _, _), do: {false, nil}

  defp canonical_entity("entity://" <> _ = uri, _ws), do: uri

  defp canonical_entity(name, ws) when is_binary(name) and name != "",
    do: "entity://user/#{ws}/#{name}"

  defp canonical_entity(_, _), do: ""
end

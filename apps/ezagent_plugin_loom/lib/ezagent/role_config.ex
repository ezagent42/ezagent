defmodule Ezagent.PluginLoom.RoleConfig do
  @moduledoc """
  Loom **per-session 角色配置**(2026-06-16,v2.1 自定义角色 + 内建超级管理员)。

  给发布物加「按登录身份解锁的隐藏入口」。两类角色:

  1. **超级管理员**(内建,key 固定 `superadmin`,不可删)—— 通过的人**只有 session 创建者**
     (作者本人,首次打开角色面板时捕获)。作者只配:`label`(按钮文本)+ `effect`/`view`/`url`
     (按钮动作),**不配人**(就是他自己)。
  2. **自定义角色**(作者自由增删)—— 每个配 `key`(`?role=<key>`)、`label`、`effect`
     (`navigate` 幕跳转 / `link` 新标签开链接)、`view`/`url`、`entities`(哪些登录账号属于它;
     一个人可同时属于多个角色)。

  发布页带 `?role=<key>` 时(此时 `?intent=` 不生效,任何 role 都看首页),salesperson 输入框
  右侧按 cookie 身份核对出现按钮。

  旁路 JSON:`~/.ezagent/<profile>/loom_roles.json`,key = session 字符串 →

      %{
        "creator" => "entity://user/<ws>/<name>" | nil,
        "super"   => %{"label","effect","view","url"},
        "roles"   => [ %{"key","label","effect","view","url","entities"}, ... ]
      }
  """

  @super_key "superadmin"
  @key_re ~r/^[a-z0-9][a-z0-9_-]*$/
  @effects ~w(navigate link)
  @max_roles 24
  @max_entities 50

  def super_key, do: @super_key

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

  defp blank_super, do: %{"label" => "", "effect" => "navigate", "view" => "", "url" => ""}

  @doc "读某 session 的角色配置(`%{\"creator\",\"super\",\"roles\"}`)。"
  @spec get(String.t(), String.t()) :: map()
  def get(ws, sid) when is_binary(ws) and is_binary(sid) do
    raw = Map.get(load_all(), skey(ws, sid), %{})
    norm_config(raw)
  rescue
    _ -> %{"creator" => nil, "super" => blank_super(), "roles" => []}
  end

  def get(_, _), do: %{"creator" => nil, "super" => blank_super(), "roles" => []}

  defp norm_config(raw) when is_map(raw) do
    roles =
      case Map.get(raw, "roles") do
        list when is_list(list) -> list |> Enum.map(&norm_role/1) |> Enum.filter(&is_map/1)
        _ -> []
      end

    %{
      "creator" => raw |> Map.get("creator") |> norm_creator(),
      "super" => norm_super(Map.get(raw, "super")),
      "roles" => roles
    }
  end

  defp norm_config(_), do: %{"creator" => nil, "super" => blank_super(), "roles" => []}

  defp norm_creator(c) when is_binary(c) and c != "", do: c
  defp norm_creator(_), do: nil

  defp norm_super(s) when is_map(s) do
    %{
      "label" => s |> Map.get("label", "") |> to_string(),
      "effect" => effect_of(Map.get(s, "effect")),
      "view" => s |> Map.get("view", "") |> to_string(),
      "url" => s |> Map.get("url", "") |> to_string()
    }
  end

  defp norm_super(_), do: blank_super()

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
  首次由作者打开面板时捕获创建者(只在 creator 仍为空、且 `uri` 是 human entity 时写一次)。
  返回 get 形状的配置。
  """
  @spec ensure_creator(String.t(), String.t(), String.t() | nil) :: map()
  def ensure_creator(ws, sid, uri) when is_binary(ws) and is_binary(sid) do
    cfg = get(ws, sid)

    if cfg["creator"] in [nil, ""] and is_binary(uri) and
         String.starts_with?(uri, "entity://user/") do
      updated = Map.put(cfg, "creator", uri)
      all = load_all() |> Map.put(skey(ws, sid), updated)
      save_all(all)
      updated
    else
      cfg
    end
  rescue
    _ -> get(ws, sid)
  end

  def ensure_creator(ws, sid, _), do: get(ws, sid)

  @doc """
  整盘写某 session 的角色配置。保留已捕获的 `creator`;写 `super`(label/effect/view/url,
  不含人)+ 自定义 `roles`(校验 key slug、去重、保留字 `superadmin` 排除;entities 里裸用户名
  补成 `entity://user/<ws>/<x>`)。返回规范化后的配置。
  """
  @spec put(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(ws, sid, config) when is_binary(ws) and is_binary(sid) and is_map(config) do
    existing = get(ws, sid)

    roles =
      config
      |> Map.get("roles", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&norm_role/1)
      |> Enum.filter(
        &(is_map(&1) and Regex.match?(@key_re, &1["key"]) and &1["key"] != @super_key)
      )
      |> Enum.uniq_by(& &1["key"])
      |> Enum.take(@max_roles)
      |> Enum.map(fn r ->
        Map.update!(r, "entities", fn es -> Enum.map(es, &canonical_entity(&1, ws)) end)
      end)

    super_cfg = norm_super(Map.get(config, "super"))

    saved = %{
      "creator" => existing["creator"],
      "super" => super_cfg,
      "roles" => roles
    }

    all = load_all() |> Map.put(skey(ws, sid), saved)
    save_all(all)
    {:ok, saved}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def put(_, _, _), do: {:error, :bad_args}

  @doc """
  核对 `entity_uri` 是否属于 key=`role` 的角色。返回 `{granted?, role_map | nil}`
  (role_map = %{"label","effect","view","url"};role 不存在 → `{false, nil}`)。

  `superadmin` 是内建角色:granted = (entity_uri == creator)。
  """
  @spec check(String.t(), String.t(), String.t(), String.t() | nil) :: {boolean(), map() | nil}
  def check(ws, sid, @super_key, entity_uri) do
    cfg = get(ws, sid)
    creator = cfg["creator"]
    granted = is_binary(entity_uri) and entity_uri != "" and entity_uri == creator
    {granted, Map.take(cfg["super"], ["label", "effect", "view", "url"])}
  rescue
    _ -> {false, nil}
  end

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

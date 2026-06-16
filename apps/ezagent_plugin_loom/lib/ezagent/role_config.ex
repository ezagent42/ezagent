defmodule Ezagent.PluginLoom.RoleConfig do
  @moduledoc """
  Loom **per-session 角色配置**(2026-06-16)。

  给发布物加「按登录身份 + 角色门控的隐藏入口」:在 loom 编辑页给三个角色
  (`operator` 接线员 / `admin` 管理员 / `superadmin` 超级管理员)各配:
  - `entities` — 哪些登录账号属于这个角色(entity URI 列表;`superadmin` 自动含**创建者**)。
  - `view` — 这个角色点按钮后 drive 到的**目标视图名**(builder 在发布页里建好的隐藏视图)。

  发布页带 `?role=<role>` 时:后端按 cookie 身份核对是否属于该角色 → 决定 salesperson
  输入框右侧按钮的状态(进入 / 登录 / 无权限)。

  旁路 JSON:`~/.ezagent/<profile>/loom_roles.json`,key = session 字符串 →

      %{ "operator"   => %{"view" => "", "entities" => []},
         "admin"      => %{"view" => "", "entities" => []},
         "superadmin" => %{"view" => "", "entities" => [], "creator" => "entity://user/.../x"} }

  `superadmin.creator` 在编辑者(= 会话创建者/拥有者)**首次打开角色配置**时捕获(那时还没存)。
  """

  @roles ~w(operator admin superadmin)
  @max_entities 50

  def roles, do: @roles

  def role_label("operator"), do: "接线员"
  def role_label("admin"), do: "管理员"
  def role_label("superadmin"), do: "超级管理员"
  def role_label(_), do: ""

  def valid_role?(r), do: r in @roles

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

  @doc "空骨架(三个角色,空 entities,无创建者)。"
  def default do
    %{
      "operator" => %{"view" => "", "entities" => []},
      "admin" => %{"view" => "", "entities" => []},
      "superadmin" => %{"view" => "", "entities" => [], "creator" => nil}
    }
  end

  @doc "读某 session 的角色配置(无 → 空骨架;补齐缺失角色)。"
  @spec get(String.t(), String.t()) :: map()
  def get(ws, sid) when is_binary(ws) and is_binary(sid) do
    stored = Map.get(load_all(), skey(ws, sid), %{})
    Map.merge(default(), normalize(stored))
  rescue
    _ -> default()
  end

  def get(_, _), do: default()

  defp normalize(m) when is_map(m) do
    Enum.into(@roles, %{}, fn role ->
      r = Map.get(m, role, %{})
      base = %{"view" => to_string(Map.get(r, "view", "")), "entities" => entities_of(r)}

      base =
        if role == "superadmin", do: Map.put(base, "creator", Map.get(r, "creator")), else: base

      {role, base}
    end)
  end

  defp normalize(_), do: default()

  defp entities_of(%{"entities" => list}) when is_list(list),
    do:
      list
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 != ""))
      |> Enum.uniq()
      |> Enum.take(@max_entities)

  defp entities_of(_), do: []

  @doc """
  整盘写某 session 的角色配置(校验角色名 + 规范化 entity URI)。`ws` 给定时,
  entities 里不是完整 `entity://` 的会补成 `entity://user/<ws>/<x>`(方便编辑者只填用户名)。
  保留已存的 `superadmin.creator`(前端不传它)。
  """
  @spec put(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(ws, sid, config) when is_binary(ws) and is_binary(sid) and is_map(config) do
    prev = get(ws, sid)

    merged =
      Enum.into(@roles, %{}, fn role ->
        incoming = Map.get(config, role, %{})

        base = %{
          "view" => incoming |> Map.get("view", "") |> to_string() |> String.trim(),
          "entities" => incoming |> entities_of() |> Enum.map(&canonical_entity(&1, ws))
        }

        base =
          if role == "superadmin",
            do: Map.put(base, "creator", get_in(prev, ["superadmin", "creator"])),
            else: base

        {role, base}
      end)

    all = load_all() |> Map.put(skey(ws, sid), merged)
    save_all(all)
    {:ok, merged}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def put(_, _, _), do: {:error, :bad_args}

  @doc "捕获创建者:`superadmin.creator` 为空时设为 `entity_uri`(编辑者首次打开角色配置时调)。"
  @spec ensure_creator(String.t(), String.t(), String.t()) :: map()
  def ensure_creator(ws, sid, entity_uri)
      when is_binary(ws) and is_binary(sid) and is_binary(entity_uri) and entity_uri != "" do
    cfg = get(ws, sid)

    case get_in(cfg, ["superadmin", "creator"]) do
      nil ->
        cfg2 = put_in(cfg, ["superadmin", "creator"], entity_uri)
        all = load_all() |> Map.put(skey(ws, sid), cfg2)
        save_all(all)
        cfg2

      _ ->
        cfg
    end
  rescue
    _ -> get(ws, sid)
  end

  def ensure_creator(ws, sid, _), do: get(ws, sid)

  @doc """
  核对 `entity_uri` 是否属于 `role`(`superadmin` 含创建者)。返回 `{granted?, view}`。
  """
  @spec check(String.t(), String.t(), String.t(), String.t() | nil) :: {boolean(), String.t()}
  def check(ws, sid, role, entity_uri) when role in @roles do
    cfg = get(ws, sid)
    r = Map.get(cfg, role, %{})
    view = Map.get(r, "view", "")
    entities = Map.get(r, "entities", [])
    creator = Map.get(r, "creator")

    granted =
      is_binary(entity_uri) and entity_uri != "" and
        (entity_uri in entities or (role == "superadmin" and entity_uri == creator))

    {granted, view}
  rescue
    _ -> {false, ""}
  end

  def check(_, _, _, _), do: {false, ""}

  defp canonical_entity("entity://" <> _ = uri, _ws), do: uri

  defp canonical_entity(name, ws) when is_binary(name) and name != "",
    do: "entity://user/#{ws}/#{name}"

  defp canonical_entity(_, _), do: ""
end

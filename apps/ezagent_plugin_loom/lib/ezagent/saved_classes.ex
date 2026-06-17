defmodule Ezagent.PluginLoom.SavedClasses do
  @moduledoc """
  Loom 的"存为模板" / "发布"实现 —— **Plan B(loom-port):纯数据,不合成模块**。

  存模板物 / 发布物是 JSON 条目,**不再**在 runtime 合成 Template Class 模块、
  **不碰** `Ezagent.TemplateRegistry`(main 的 plugin gate「declare don't call」
  禁止插件调 `*Registry`)。`save_one/4` 只写盘;`open` / `fork` / `derive` 时由
  `instantiate_from_data/3` 读条目的 `saved_state` + `published` 标记,直接实例化
  `session.loom`(发布物冻结无 builder;存模板可编辑有 builder)。

  ## 持久化

  JSON 文件:`~/.ezagent/<EZAGENT_PROFILE>/loom_saved_classes.json`。无 boot-time
  注册步骤 —— 条目即数据,按需 `load_all/0` 读取。

  ## 同名再保存

  `save_one/4` 直接覆盖同 key 的旧条目(纯 map put)。

  ## 删除

  `delete_one/1` 从 map 删 key 后写盘。
  """

  require Logger

  @class_prefix "session."

  # --- file IO ---------------------------------------------------------

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_saved_classes.json")
  end

  def load_all do
    case File.read(file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp save_all(map) when is_map(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
  end

  # --- public API ------------------------------------------------------

  @doc """
  List saved classes (for UI). Returns
  `[%{name, description, saved_at, published}]`. `published` is `true` for
  classes minted by loom 发布 (immutable + share-link) — the loom UI filters
  these out of its editable-template list (they are a distinct concept).
  """
  def list_entries do
    load_all()
    |> Enum.map(fn {name, entry} ->
      %{
        "name" => name,
        "description" => Map.get(entry, "description"),
        "saved_at" => Map.get(entry, "saved_at"),
        "published" => Map.get(entry, "published", false) == true
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Resolve a 发布 share-link token → `{:ok, class_name, ws}` or `:error`.

  Published entries carry `%{"published" => true, "token" => <hex>, "ws" => <ws>}`
  (set by `EzagentPluginLoom.WebPlug` at publish time). The token is the opaque
  capability in `/loom/p/<token>`; this is the only lookup path from token back
  to the immutable Template Class + its origin workspace.
  """
  @spec find_by_token(String.t()) :: {:ok, String.t(), String.t()} | :error
  def find_by_token(token) when is_binary(token) and token != "" do
    load_all()
    |> Enum.find_value(:error, fn {class_name, entry} ->
      if Map.get(entry, "token") == token do
        {:ok, class_name, Map.get(entry, "ws")}
      end
    end)
  end

  def find_by_token(_), do: :error

  @doc "读发布物(token)随带的知识库 md(无则空串)。供 open_published seed 消费会话。"
  @spec knowledge_for_token(String.t()) :: String.t()
  def knowledge_for_token(token) when is_binary(token) and token != "" do
    load_all()
    |> Enum.find_value("", fn {_cn, entry} ->
      if Map.get(entry, "token") == token, do: Map.get(entry, "knowledge", "")
    end)
  end

  def knowledge_for_token(_), do: ""

  @doc "读发布物(token)随带的角色门控配置(无则空 map)。供 open_published seed 消费会话。"
  @spec roles_for_token(String.t()) :: map()
  def roles_for_token(token) when is_binary(token) and token != "" do
    load_all()
    |> Enum.find_value(%{}, fn {_cn, entry} ->
      if Map.get(entry, "token") == token, do: Map.get(entry, "roles", %{})
    end)
  end

  def roles_for_token(_), do: %{}

  @doc "读发布物(token)随带的多页结构(无则空 map)。供 open_published seed 消费会话。"
  @spec pages_for_token(String.t()) :: map()
  def pages_for_token(token) when is_binary(token) and token != "" do
    load_all()
    |> Enum.find_value(%{}, fn {_cn, entry} ->
      if Map.get(entry, "token") == token, do: Map.get(entry, "pages", %{})
    end)
  end

  def pages_for_token(_), do: %{}

  @doc "读发布物(token)的整盘 saved_state(衍生**可编辑**新会话用)。无 → nil。"
  @spec saved_state_for_token(String.t()) :: map() | nil
  def saved_state_for_token(token) when is_binary(token) and token != "" do
    load_all()
    |> Enum.find_value(fn {_cn, entry} ->
      if Map.get(entry, "token") == token do
        case Map.get(entry, "saved_state") do
          %{} = ss -> ss
          _ -> nil
        end
      end
    end)
  end

  def saved_state_for_token(_), do: nil

  @doc """
  List published templates(发布历史)—— 只返回 `published: true` 的条目,带 token /
  ws / 说明 / 发布时间 / 来源 session,**新的在前**。loom 发布弹窗用它展示历史 + 链接,
  关掉弹窗也能找回。
  """
  @spec list_published() :: [map()]
  def list_published do
    load_all()
    |> Enum.filter(fn {_cn, e} -> Map.get(e, "published") == true end)
    |> Enum.map(fn {class_name, e} ->
      %{
        "class_name" => class_name,
        "token" => Map.get(e, "token"),
        "ws" => Map.get(e, "ws"),
        "description" => Map.get(e, "description"),
        "published_at" => Map.get(e, "saved_at"),
        "published_from" => Map.get(e, "published_from")
      }
    end)
    |> Enum.sort_by(& &1["published_at"], :desc)
  end

  @doc """
  Save a new (or overwrite an existing) Class.

  `name_suffix` is the user-typed name (e.g. "incubator_portal"); the full
  Class name registered is `"session.<suffix>"`. Only `[a-zA-Z0-9_-]+`.
  `saved_state` is a map (e.g. `%{"orchestrator" => %{...}}`).
  """
  @spec save_one(String.t(), map(), String.t() | nil, map()) ::
          {:ok, String.t()} | {:error, term()}
  def save_one(name_suffix, saved_state, description \\ nil, meta \\ %{})
      when is_binary(name_suffix) and is_map(meta) do
    if Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name_suffix) do
      class_name = @class_prefix <> name_suffix

      # `meta` carries optional extra fields merged into the persisted entry —
      # loom 发布 passes `%{"published" => true, "token" => ..., "ws" => ...}`
      # so the same Class machinery (module synthesis + boot re-register) backs
      # both manual save-as-template and immutable published templates.
      entry =
        %{
          "saved_state" => saved_state,
          "description" => description,
          "saved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
        |> Map.merge(meta)

      map = load_all() |> Map.put(class_name, entry)
      save_all(map)

      # Plan B(loom-port):发布/存模板物 = **纯数据**,不再合成 Template Class 模块、不碰
      # `TemplateRegistry`(main 的 plugin「declare don't call」gate 禁止插件调 *Registry)。
      # open/fork/derive 时由 `instantiate_from_data/3` 直接实例化 `session.loom`。
      {:ok, class_name}
    else
      {:error, :invalid_name}
    end
  end

  @doc "Delete a saved Class by full class name (e.g. `session.incubator_portal`)."
  @spec delete_one(String.t()) :: :ok | {:error, :not_found}
  def delete_one(class_name) when is_binary(class_name) do
    map = load_all()

    case Map.pop(map, class_name) do
      {nil, _} ->
        {:error, :not_found}

      {_removed, new_map} ->
        save_all(new_map)
        :ok
    end
  end

  @doc """
  Plan B(loom-port)—— 数据驱动实例化(取代旧的合成-Template-Class-模块流程)。

  读 `class_name`(`session.pub_*` / 存模板备份)的 entry,把 `saved_state` + `published`
  标记注入,直接实例化 `session.loom`(发布物冻结无 builder;存模板可编辑有 builder)。
  open_published / fork / derive 都走这条,**不碰 TemplateRegistry**(顺从 main plugin gate)。
  """
  @spec instantiate_from_data(String.t(), String.t(), URI.t()) ::
          {:ok, [URI.t()]} | {:error, term()}
  def instantiate_from_data(class_name, session_name, %URI{} = ws_uri)
      when is_binary(class_name) and is_binary(session_name) do
    case load_all() |> Map.get(class_name) do
      %{} = entry ->
        saved_state = Map.get(entry, "saved_state") || %{}
        published? = Map.get(entry, "published") == true

        tmpl = %{
          "class" => "session.loom",
          "session_name" => session_name,
          "no_builder" => published?,
          "saved_state" => saved_state
        }

        Ezagent.PluginLoom.Template.LoomSession.instantiate("session.loom", tmpl, ws_uri)

      _ ->
        {:error, :not_found}
    end
  end
end

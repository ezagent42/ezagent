defmodule Ezagent.PluginLoom.SavedClasses do
  @moduledoc """
  Loom 的"存为模板"实现:**Class 级**(与 `session.loom` 同级)。

  每次保存生成一个新 Template Class 模块,template_name 形如
  `session.<user-name>`,在 `Ezagent.TemplateRegistry` 注册;
  `/workspaces/<ws>` 的 "Add template" Class picker 自动看见。

  ## 持久化

  JSON 文件:`~/.ezagent/<EZAGENT_PROFILE>/loom_saved_classes.json`。
  Plugin Application 的 `after_boot/0` 调 `register_all_from_disk/0`,
  把文件里每条 reincarnate 成模块 + 注册。

  ## 生成模块

  `Module.create/3` 在 runtime 编译模块,模块 body 引用闭包式的 `@saved_state`
  常量。`instantiate/3` 把 `tmpl` 里的 `"class"` 重写成 `"session.loom"`
  + 注入 `saved_state`,直接 delegate 给
  `Ezagent.PluginLoom.Template.LoomSession.instantiate/3`(避免重复整个 spawn
  + team + seed 流程的代码,只换"什么 source / persona")。

  ## 同名再保存

  覆盖旧条目;`:code.purge/1` + `:code.delete/1` 把老模块卸了,再
  `Module.create` 新的。

  ## 删除

  `TemplateRegistry` 没有 deregister API,这里直接 `:ets.delete/2`
  那张表(table 名 `Ezagent.TemplateRegistry.table/0`)。模块本身 purge。
  """

  require Logger

  alias Ezagent.TemplateRegistry

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

      case register_one(class_name, entry) do
        :ok -> {:ok, class_name}
        {:error, _} = err -> err
      end
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
        deregister_one(class_name)
        :ok
    end
  end

  @doc """
  Read the JSON file and (re)register every saved Class.
  Called from `EzagentPluginLoom.Application.after_boot/0`.
  """
  def register_all_from_disk do
    load_all()
    |> Enum.each(fn {class_name, entry} ->
      try do
        case register_one(class_name, entry) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "SavedClasses: register #{class_name} returned error: #{inspect(reason)}"
            )
        end
      rescue
        e ->
          Logger.warning("SavedClasses: register #{class_name} raised: #{inspect(e)}")
      end
    end)
  end

  # --- module synthesis ------------------------------------------------

  defp register_one(class_name, entry) when is_binary(class_name) do
    saved_state = Map.get(entry, "saved_state") || %{}
    module = module_for(class_name)

    # Hot-replace if already loaded (e.g., re-save same suffix).
    if :code.is_loaded(module) do
      _ = :code.purge(module)
      _ = :code.delete(module)
    end

    contents =
      quote bind_quoted: [class_name: class_name, saved_state: Macro.escape(saved_state)] do
        @behaviour Ezagent.Kind.Template
        # 关键:也要实现 Ezagent.UI.Form,否则 `Ezagent.UI.Form.list_form_classes/0`
        # 用 `function_exported?(module, :form_fields, 0)` 过滤会把这条筛掉,
        # /workspaces/<ws> 的 Add template Class picker 就看不见。
        @behaviour Ezagent.UI.Form

        @class_name class_name
        @saved_state saved_state

        @impl Ezagent.Kind.Template
        def template_name, do: @class_name

        @impl Ezagent.Kind.Template
        def validate(%{"class" => name, "session_name" => sn})
            when name == @class_name and is_binary(sn) and sn != "",
            do: :ok

        def validate(%{"class" => name}) when name == @class_name,
          do: {:error, :missing_or_empty_session_name}

        def validate(_), do: {:error, :wrong_class}

        @impl Ezagent.Kind.Template
        def instantiate(tmpl_name, %{"class" => @class_name, "session_name" => _} = tmpl, ws_uri) do
          # 委托给 LoomSession,把 class 重写成 "session.loom"、saved_state 注入。
          # `Map.merge(saved_state, tmpl)` 让 tmpl 里的字段(尤其 session_name)
          # 不被 saved_state 覆盖,但 saved_state 的 orchestrator 快照覆盖默认。
          augmented =
            tmpl
            |> Map.put("class", "session.loom")
            # 2026-06-05 — 发布物(SavedClass)衍生的 session 一律无 v0:base 冻结,
            # 只能 user_schema 叠加。只有最初的 session.loom 有 v0。
            |> Map.put("no_builder", true)
            |> then(fn t -> Map.merge(%{"saved_state" => @saved_state}, t) end)

          Ezagent.PluginLoom.Template.LoomSession.instantiate(tmpl_name, augmented, ws_uri)
        end

        def instantiate(_tmpl_name, tmpl, _ws_uri),
          do: {:error, {:invalid_template, tmpl}}

        # --- cleanup(tmpl_name, tmpl, ws_uri) — `WorkspaceDetailLive` calls
        # this on Remove if the function is exported. Delegate to LoomSession
        # which knows how to terminate the team + snapshots + Feishu binding.
        def cleanup(tmpl_name, %{"class" => @class_name} = tmpl, ws_uri) do
          augmented = Map.put(tmpl, "class", "session.loom")
          Ezagent.PluginLoom.Template.LoomSession.cleanup(tmpl_name, augmented, ws_uri)
        end

        def cleanup(_tmpl_name, _tmpl, _ws_uri), do: :ok

        # --- session_uris_for_recipe — visibility filter for /sessions
        # dropdown. Delegates to LoomSession (which produces
        # `session://loom/<ws>/<sn>` regardless of the saved-class
        # specialization, because `instantiate/3` itself delegates).
        # See LoomSession.session_uris_for_recipe/3 for rationale.
        def session_uris_for_recipe(tmpl_name, %{"class" => @class_name} = tmpl, ws_uri) do
          augmented = Map.put(tmpl, "class", "session.loom")

          Ezagent.PluginLoom.Template.LoomSession.session_uris_for_recipe(
            tmpl_name,
            augmented,
            ws_uri
          )
        end

        def session_uris_for_recipe(_tmpl_name, _tmpl, _ws_uri), do: []

        # --- saved?/0 + delete_self!/0 — duck-typed deletability ---------
        #
        # The admin LV (workspace_detail_live) renders a 🗑️ next to any
        # Class in the Add-template picker whose module returns
        # `saved?/0 == true`, then calls `delete_self!/0` on click.
        # This keeps liveview plugin-agnostic — it never needs to know
        # `Ezagent.PluginLoom.SavedClasses` exists.
        #
        # Built-in Classes (LoomSession, CcAgent, etc.) don't implement
        # these → no delete button, can't be removed via UI.
        def saved?, do: true

        def delete_self! do
          Ezagent.PluginLoom.SavedClasses.delete_one(@class_name)
        end

        # --- Ezagent.UI.Form ---------------------------------------------

        @impl Ezagent.UI.Form
        def form_fields do
          [
            %{
              name: "session_name",
              type: :text,
              label: "Session name",
              required: true,
              placeholder: "<short-name> (becomes session://#{@class_name}/<ws>/<name>)"
            }
          ]
        end

        @impl Ezagent.UI.Form
        def form_to_args(params) do
          %{
            "class" => @class_name,
            "session_name" => Map.get(params, "session_name", ""),
            "members" => []
          }
        end
      end

    try do
      Module.create(module, contents, Macro.Env.location(__ENV__))
      TemplateRegistry.register(module)
    rescue
      e -> {:error, e}
    end
  end

  defp deregister_one(class_name) do
    table = TemplateRegistry.table()
    _ = :ets.delete(table, class_name)

    module = module_for(class_name)

    if :code.is_loaded(module) do
      _ = :code.purge(module)
      _ = :code.delete(module)
    end

    :ok
  end

  defp module_for(class_name) do
    suffix = String.replace_prefix(class_name, @class_prefix, "")
    sanitized = String.replace(suffix, ~r/[^a-zA-Z0-9]/, "_")
    camelized = Macro.camelize(sanitized)
    String.to_atom("Elixir.Ezagent.PluginLoom.Template.Generated." <> camelized)
  end
end

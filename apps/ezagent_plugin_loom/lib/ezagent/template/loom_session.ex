defmodule Ezagent.PluginLoom.Template.LoomSession do
  @moduledoc """
  Loom **Session** Template Class — declare a loom session by name; on
  `instantiate/3` it spawns the bare Session Kind, assembles the loom
  team (orchestrator + 2 workers via `EzagentPluginLoom.Team.ensure_team/1`),
  and joins any declared members.

  ## Why this exists

  The imperative `EzagentPluginLoom.Bootstrap.run/1` assembled the team
  per-visitor. This Template Class exposes the SAME assembly as a
  **pickable SessionTemplate** so creating a loom session through the
  workspace UI (or `Workspace.add_template` + instantiate) auto-populates
  `loomorch_<name>` + `loomworker_<name>_policy` + `loomworker_<name>_company`
  — instead of getting a bare session (the question "why no orchestrator
  in my UI-created session" was exactly this gap).

  Uses `SpawnRegistry.spawn/1` directly (NOT `EzagentDomainInstanceMessage.create_session/3`),
  so it does NOT also spin up the generic `cc` auto-orchestrator — the
  loom team is the only crew in the room.

  ## Template data shape

      %{
        "class" => "session.loom",          # required
        "session_name" => "loom-demo",       # required → session://loom/<ws>/loom-demo
        "members" => ["entity://user/system/admin"],  # optional extra members (URIs)
        # 2026-06-01 — save-as-template:把当前 orchestrator 的 :loom_source 快照
        # 进模板。两字段都可选;缺省则 fallback 到 Prompts.loom_seed_source/0
        # 那张内置欢迎页 + "初始页"。
        "loom_source" => "...jsx...",        # optional, seeded page source
        "loom_summary" => "登录页 v2"          # optional, page summary
      }

  ## Triggering

  Each session member must still be `@mention`ed for the orchestrator to
  act (default mention-gated routing). To make a UI user's messages reach
  the orchestrator without an explicit @, a per-session routing rule would
  be added here — deferred (see moduledoc note in `EzagentPluginLoom.Team`).

  ## Idempotency

  `SpawnRegistry.spawn/1` returns the existing pid for an already-alive
  Kind; `Team.ensure_team/1` + `chat.join` are idempotent reconcilers.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  alias EzagentPluginLoom.{Feishu, Team}

  @impl Ezagent.Kind.Template
  def template_name, do: "session.loom"

  @impl Ezagent.Kind.Template
  def validate(%{"class" => "session.loom", "session_name" => n}) when is_binary(n) and n != "",
    do: :ok

  def validate(%{"class" => "session.loom"}), do: {:error, :missing_or_empty_session_name}
  def validate(%{"class" => other}), do: {:error, {:wrong_class, other}}
  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"session_name" => session_name} = tmpl, %URI{} = workspace_uri) do
    ws = workspace_uri.host
    session_uri = Ezagent.URI.new!("session://loom/#{ws}/#{session_name}")

    # 2026-06-01 save-as-template:可选 `saved_state` 字段,装上一个 session 的
    # orchestrator slice 快照(`persona` + `loom_source`)。有就用 Kind.spawn 把
    # orchestrator 提前 init,让 LoomOrchestrator.init_slice 自然吃 args;
    # Team.ensure_team 后到再用幂等 spawn 把 orchestrator 当 already_started 跳过。
    # 没有 saved_state → fallback 走默认 seed 页 + 默认 persona。
    saved_state = Map.get(tmpl, "saved_state") || %{}
    saved_orch = Map.get(saved_state, "orchestrator") || %{}

    seed_source =
      Map.get(saved_orch, "loom_source") ||
        Map.get(tmpl, "loom_source") ||
        EzagentPluginLoom.Prompts.loom_seed_source()

    seed_summary = Map.get(tmpl, "loom_summary") || "初始页"

    # 2026-06-10 — 页面助手(Stitch)样式。发布/快照时由 read_orchestrator_snapshot
    # 存进 saved_state.orchestrator.stitch_config;这里取出 → seed 进 page_update span
    # (前端 extractStitchConfig 从这条消息读),让 published/pub 会话保持作者配的样式。
    seed_stitch_config = Map.get(saved_orch, "stitch_config")

    saved_workers = Map.get(saved_state, "workers") || []
    worker_themes = worker_themes_from_saved(saved_workers)
    # 2026-06-05 — 发布物 fork 出的 session 不含 v0(base 冻结,只能 user_schema
    # 叠加,不能 @v0 重写源码)。原 session.loom 不带此标记 → v0 照常。
    include_v0? = Map.get(tmpl, "no_v0") != true

    with {:ok, _session_pid} <- spawn_session(session_uri),
         :ok <- pre_spawn_orchestrator_if_saved(ws, session_name, saved_orch),
         :ok <- pre_spawn_workers_if_saved(ws, session_name, saved_workers),
         {:ok, %{orchestrator: _orch, workers: _workers}} <-
           Team.ensure_team(session_uri, worker_themes: worker_themes, include_v0: include_v0?),
         :ok <- join_members(session_uri, Map.get(tmpl, "members", [])) do
      # 2026-06-01 redesign: seed a `<span type="page_update">` message into
      # the session so the loom-view bridge has something to render on first
      # open. Best-effort (don't fail instantiate if the dispatch errors).
      # Idempotent (2026-06-01): skip if a page_update span already exists
      # in chat — `Workspace.add_template/3` triggers instantiate twice
      # via an ESR-layer slice-change side-effect (deferred root-cause fix),
      # leading to duplicate seeds before this guard.
      maybe_seed_loom_source(session_uri, seed_source, seed_summary, seed_stitch_config)

      # Best-effort one-way Feishu mirror (gated by FEISHU_MIRROR_ENABLED=1),
      # mirroring EzagentPluginLoom.Bootstrap — so a UI-created loom session
      # also mirrors to the demo Feishu group, not just the script path.
      # Failure must NOT fail instantiate; idempotent on re-add.
      maybe_bind_feishu(session_uri)
      {:ok, [session_uri]}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  @doc """
  Tear down a session previously instantiated from this Template Class.

  Called by `WorkspaceDetailLive.handle_event("remove_template", ...)`
  when an operator clicks **Remove** on a Session template row. The LV
  uses `function_exported?(module, :cleanup, 3)` as the duck-typing
  contract — no formal callback in `Ezagent.Kind.Template` behaviour
  (yet); plugins that want "remove template = also kill spawned session"
  semantics implement this.

  Steps for a loom session at `session://loom/<ws>/<session_name>`:
  1. `Ezagent.Lifecycle.destroy/2` each Kind(session + team + custom
     workers): runs destroy hooks → terminates the process → clears the
     snapshot AND the `ever_created` marker. Clearing the marker is what
     the previous hand-rolled `terminate + snapshot delete` missed —
     without it a removed session lazy-revives into a ghost on the next
     dispatch that hits its URI (see `session_uris_for_recipe/3`).
  2. Drop the Feishu external_mirror_bindings row(if present)— the
     Session's `ExternalMirror` Behavior has no custom destroy hook, so
     `destroy/2` does NOT clear the binding row; we do it explicitly.

  Best-effort: every sub-step is wrapped + ignored on error. The LV
  treats `cleanup/3` as fire-and-forget — caller has already done the
  user-facing `remove_template` and we don't want a cleanup hiccup to
  fail that.

  Members table / messages / message_routings / read_markers / audit
  invocations are **NOT** touched here — chat history is the user's
  artifact, not Template Class state. If they want a deep wipe, use
  the `cleanup_loom_sessions.sh` script.
  """
  def cleanup(_tmpl_name, %{"session_name" => session_name}, %URI{host: ws})
      when is_binary(session_name) and session_name != "" and is_binary(ws) do
    Logger.info("LoomSession.cleanup: tearing down session=#{session_name} workspace=#{ws}")

    session_uri = Ezagent.URI.new!("session://loom/#{ws}/#{session_name}")

    # 2026-06-01 — 加 loommeta_<sid>;之前只清了 orchestrator + v0 + 2 worker。
    # 自定义 worker(painter / lawyer 等用户加的)也得清,但我们这里硬列预制 4
    # 名;custom worker 通过 chat.members 扫描另算。
    team_uri_strs = [
      "entity://agent/#{ws}/loomorch_#{session_name}",
      "entity://agent/#{ws}/loomv0_#{session_name}",
      "entity://agent/#{ws}/loommeta_#{session_name}",
      "entity://agent/#{ws}/loomworker_#{session_name}_policy",
      "entity://agent/#{ws}/loomworker_#{session_name}_company"
    ]

    team_uris = Enum.map(team_uri_strs, &Ezagent.URI.new!/1)

    # 扫 chat.members 把 custom workers(painter 等)也找出来
    custom_worker_uris = find_custom_workers(session_uri, session_name)
    all_uris = [session_uri | team_uris] ++ custom_worker_uris

    Logger.info(
      "LoomSession.cleanup: destroying #{length(all_uris)} URIs (session + #{length(team_uris)} team + #{length(custom_worker_uris)} custom)"
    )

    for uri <- all_uris do
      result = safe_destroy(uri)

      Logger.debug("LoomSession.cleanup: #{URI.to_string(uri)} destroy=#{inspect(result)}")
    end

    _ = safe_unbind_feishu(session_uri)

    Logger.info("LoomSession.cleanup: done for #{URI.to_string(session_uri)}")
    :ok
  end

  # 扫 session 的 chat.members,找 `loomworker_<sid>_<theme>` 但不是预制 theme 的。
  defp find_custom_workers(session_uri, sid) do
    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, %{members: members}} when is_map(members) ->
        prefix = "loomworker_#{sid}_"

        members
        |> Map.keys()
        |> Enum.flat_map(fn %URI{path: "/" <> rest} = uri ->
          case String.split(rest, "/") do
            [_ws, name] ->
              if String.starts_with?(name, prefix) do
                theme = String.replace_prefix(name, prefix, "")

                if theme in ["policy", "company"] do
                  []
                else
                  [uri]
                end
              else
                []
              end

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  def cleanup(_tmpl_name, _tmpl, _ws_uri), do: :ok

  @doc """
  Declare the Session URIs this template recipe would spawn.

  Used by the admin LV (`/sessions` dropdown) to filter out **ghost
  sessions**: a Kind instance that's alive in `KindRegistry` but whose
  backing workspace template has been removed. Without this filter,
  `remove_template` only kills the Kind once via fire-and-forget
  `cleanup/3`, but lazy-spawn-from-snapshot paths
  (`Invocation.attempt_lazy_spawn_and_redispatch` /
  `StateRebuilder.snapshot_exists?`) can revive the session whenever
  any in-flight dispatch hits the URI (iframe still polling, Feishu
  webhook arrival, etc.). The operator's mental model is "Remove =
  invisible", so we make visibility a function of "is the template
  still declared" not "is a Kind alive".

  Optional duck-typed callback (no formal `Ezagent.Kind.Template`
  contract). Templates that don't own session URIs simply don't
  implement it; the LV falls back to "treat as no declared URIs".

  See user feedback "我把session删了，而sessions页面还是能看到遗留" (2026-06-02).
  """
  def session_uris_for_recipe(_tmpl_name, %{"session_name" => sn}, %URI{host: ws})
      when is_binary(sn) and sn != "" and is_binary(ws) do
    [Ezagent.URI.new!("session://loom/#{ws}/#{sn}")]
  end

  def session_uris_for_recipe(_tmpl_name, _recipe, _ws_uri), do: []

  # 走框架标准 Kind 销毁路径(Allen 2026-06-03 "基于 lifecycle,不要基于特定
  # 函数")。`Ezagent.Lifecycle.destroy/2` 顺序:跑 developer destroy hook →
  # terminate 进程 → 清 snapshot + `ever_created` marker。清 marker 是旧的手搓
  # "terminate + 直接删快照" 漏掉的一步 —— 漏了它,删过的 session 会
  # 在下次命中其 URI 的 dispatch 时 lazy-revive 成 ghost。幂等:已不存在的 URI
  # 返回 :ok。cleanup 跑在 LV 进程(非任一 Kind 进程),不会触发 destroy/2 的
  # self-destroy guard。best-effort 包裹:一个 URI 失败不中断其余(fire-and-forget)。
  defp safe_destroy(uri) do
    Ezagent.Lifecycle.destroy(uri, :destroy)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_unbind_feishu(session_uri) do
    try do
      Ezagent.ExternalMirror.BindingRow.delete_by_natural_key(
        session_uri,
        "feishu",
        EzagentPluginLoom.Feishu.chat_id()
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # Idempotent wrapper around `seed_loom_source/3`. If the session already
  # has a `<span type="page_update">` message in recent history, skip (the
  # bridge will pick it up). Else seed once.
  defp maybe_seed_loom_source(%URI{} = session_uri, source, summary, stitch_config \\ nil)
       when is_binary(summary) do
    if already_seeded?(session_uri) do
      :ok
    else
      seed_loom_source(session_uri, source, summary, stitch_config)
    end
  end

  # 2026-06-10 — 幂等判据:**看 session 里有没有 page_update 消息**(前端就是从这条消息
  # 读页面文件的,所以判据必须看消息、**不能看 orchestrator slice**)。
  #
  # 坑历史:
  #   - 原来只看最近 5 条 → Stitch 对话灌多了把 page_update 挤出窗口 → 误判没 seed →
  #     boot 又 seed 默认页(zuatu 反复变回初始页)。
  #   - 改成看 orchestrator slice 又坑了发布:pub 会话的 orchestrator 从发布类 saved_state
  #     预启(slice 里已有源),于是误判"已 seed" → **跳过播 page_update 消息** → 前端没文件
  #     → 发布预览空白。
  # 正解:**宽窗口看消息**(200 条),既不被 Stitch 挤掉,又不会让"slice 有源但没消息"
  # 的 pub 会话漏 seed。
  defp already_seeded?(%URI{} = session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(200)
    |> Enum.any?(&page_update_msg?/1)
  rescue
    _ -> false
  end

  defp page_update_msg?(%Ezagent.Message{body: %{text: t}}) when is_binary(t),
    do: String.contains?(t, ~s(<span type="page_update"))

  defp page_update_msg?(%Ezagent.Message{body: %{"text" => t}}) when is_binary(t),
    do: String.contains?(t, ~s(<span type="page_update"))

  defp page_update_msg?(_), do: false

  # 2026-06-01 redesign: emit a system `<span type="page_update">` chat message
  # so the loom-view bridge picks it up via `getHistory()` on first open. Sender
  # = `system://session-internal` (same principal LoomSession uses for joins);
  # `mentions = []` (session-wide announcement, not addressed to anyone).
  # Best-effort; failures logged + swallowed.
  defp seed_loom_source(%URI{} = session_uri, source, summary, stitch_config \\ nil)
       when is_binary(summary) do
    # 2026-06-02 多文件:source 可能是 files map(新)或字符串(旧 saved/seed)→ 归一。
    files = EzagentPluginLoom.Prompts.normalize_source(source)

    # 2026-06-10 — 作者配过 Stitch 样式就一并塞进 span(键名 `stitchConfig`,跟 v0
    # 发的 page_update 一致),前端 extractStitchConfig 据此渲染 published/pub 助手。
    span_payload =
      %{
        "files" => files,
        "source" => Map.get(files, "/App.jsx", ""),
        "summary" => summary
      }
      |> maybe_put_stitch_config(stitch_config)

    body = EzagentPluginLoom.Span.span("page_update", span_payload)

    sender = Ezagent.SystemPrincipal.uri("session-internal")
    msg = Ezagent.Message.new(sender, %{text: body, attachments: []}, mentions: [])
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: sender,
        caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
        reply: :ignore
      }
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("LoomSession: seed loom_source dispatch failed — #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_put_stitch_config(payload, cfg) when is_map(cfg) and map_size(cfg) > 0,
    do: Map.put(payload, "stitchConfig", cfg)

  defp maybe_put_stitch_config(payload, _), do: payload

  # Gated + best-effort, identical semantics to Bootstrap.maybe_bind_feishu/1.
  defp maybe_bind_feishu(%URI{} = session_uri) do
    if System.get_env("FEISHU_MIRROR_ENABLED") == "1" do
      case Feishu.bind(session_uri) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("LoomSession: feishu bind skipped — #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  defp spawn_session(%URI{} = session_uri) do
    case Ezagent.SpawnRegistry.spawn(session_uri) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  # Pre-spawn the orchestrator with init args derived from saved snapshot,
  # so `LoomOrchestrator.init_slice/1` picks up `persona` + `initial_loom_source`
  # (both honored by the existing init_slice signature). `Ezagent.Kind.spawn/2`
  # routes to the right supervisor (LoomOrchestrator declares
  # `EzagentDomainInstanceMessage.AgentSupervisor`). 后到的 Team.ensure_team 因 SpawnRegistry
  # 的幂等性,看到 orchestrator 已经在,返回 :already_started → 不覆盖。
  # 没 saved snapshot → 跳过,让 Team.ensure_team 自己启默认 orchestrator。
  # 2026-06-01 Phase 2 — 把 saved_workers 数组转成 theme 列表传给 Team.ensure_team。
  # 空数组 → 用 Team 自带默认 ["policy", "company"](向后兼容)。
  defp worker_themes_from_saved([]), do: ["policy", "company"]

  defp worker_themes_from_saved(saved_workers) when is_list(saved_workers) do
    saved_workers
    |> Enum.map(&Map.get(&1, "theme"))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp worker_themes_from_saved(_), do: ["policy", "company"]

  # 预 spawn 每个 saved worker,用 saved system_prompt + role 作 init args。
  # LoomWorker.init_slice 读 `:system_prompt` / `:role`。Team.ensure_team
  # 后到的 spawn_step 看到已经在,幂等返回。
  defp pre_spawn_workers_if_saved(_ws, _sid, []), do: :ok

  defp pre_spawn_workers_if_saved(ws, sid, saved_workers) when is_list(saved_workers) do
    Enum.each(saved_workers, fn worker ->
      theme = Map.get(worker, "theme") || ""
      sp = Map.get(worker, "system_prompt") || ""
      role = Map.get(worker, "role") || theme

      if theme != "" do
        worker_uri = Ezagent.URI.new!("entity://agent/#{ws}/loomworker_#{sid}_#{theme}")

        args = %{
          uri: worker_uri,
          system_prompt: sp,
          role: role
        }

        case Ezagent.Kind.spawn(Ezagent.Entity.LoomWorker, args) do
          {:ok, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning("LoomSession: worker pre_spawn #{theme} failed: #{inspect(reason)}")
        end
      end
    end)

    :ok
  end

  defp pre_spawn_workers_if_saved(_, _, _), do: :ok

  defp pre_spawn_orchestrator_if_saved(_ws, _sid, saved) when map_size(saved) == 0, do: :ok

  defp pre_spawn_orchestrator_if_saved(ws, sid, saved) when is_map(saved) do
    orch_uri = Ezagent.URI.new!("entity://agent/#{ws}/loomorch_#{sid}")

    args = %{
      uri: orch_uri,
      persona: to_string(Map.get(saved, "persona") || "visitor"),
      # 2026-06-02 多文件:saved loom_source 可能是 files map(新)或字符串(旧)。
      # 原样传,orchestrator init_slice 用 normalize_source 归一。
      initial_loom_source: Map.get(saved, "loom_source") || %{},
      # 2026-06-10 — 把作者配的 Stitch 样式注回 orchestrator slice,这样从此 fork
      # 出去的会话再 publish 时 read_orchestrator_snapshot 还能带上它。
      initial_stitch_config: Map.get(saved, "stitch_config")
    }

    case Ezagent.Kind.spawn(Ezagent.Entity.LoomOrchestrator, args) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        # 这条不应该走到 —— save-as-template flow 拒了重名,session 一定是新的。
        # 但 idempotent 兜底:已经在就接受现状,不动它的 slice。
        Logger.warning(
          "LoomSession: orchestrator already_started during pre_spawn for #{URI.to_string(orch_uri)} — " <>
            "slice NOT overwritten with snapshot. (Re-instantiate?)"
        )

        :ok

      {:error, reason} ->
        {:error, {:orch_pre_spawn_failed, reason}}
    end
  end

  defp join_members(%URI{} = session_uri, members) when is_list(members) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    Enum.each(members, fn member_uri_str ->
      case safe_member_uri(member_uri_str) do
        {:ok, member_uri} ->
          _ =
            Ezagent.Invocation.dispatch(%Ezagent.Invocation{
              target: target,
              mode: :cast,
              args: %{member: member_uri},
              ctx: %{
                caller: Ezagent.SystemPrincipal.uri("template-materialize"),
                caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
                reply: :ignore
              }
            })

        _ ->
          Logger.warning(
            "LoomSession: bad member URI #{inspect(member_uri_str)} for " <>
              "#{URI.to_string(session_uri)}, skipping"
          )
      end
    end)

    :ok
  end

  defp safe_member_uri(s) when is_binary(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> :error
  end

  defp safe_member_uri(_), do: :error

  # --- Ezagent.UI.Form -------------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "session_name",
        type: :text,
        label: "Session name",
        required: true,
        placeholder: "loom-demo (becomes session://loom/<ws>/loom-demo)"
      }
    ]
  end

  @impl Ezagent.UI.Form
  def form_to_args(params) do
    %{
      "class" => template_name(),
      "session_name" => Map.get(params, "session_name", ""),
      "members" => []
    }
  end
end

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

  Uses `SpawnRegistry.spawn/1` directly (NOT `EzagentDomainChat.create_session/3`),
  so it does NOT also spin up the generic `cc` auto-orchestrator — the
  loom team is the only crew in the room.

  ## Template data shape

      %{
        "class" => "session.loom",          # required
        "session_name" => "loom-demo",       # required → session://loom/<ws>/loom-demo
        "members" => ["entity://user/system/admin"]  # optional extra members (URIs)
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
    session_uri = Ezagent.URI.parse!("session://loom/#{ws}/#{session_name}")

    with {:ok, _session_pid} <- spawn_session(session_uri),
         {:ok, %{orchestrator: _orch, workers: _workers}} <- Team.ensure_team(session_uri),
         :ok <- join_members(session_uri, Map.get(tmpl, "members", [])) do
      # 2026-06-01 redesign: seed a `<span type="page_update">` message into
      # the session so the loom-view bridge has something to render on first
      # open. Best-effort (don't fail instantiate if the dispatch errors).
      seed_loom_source(
        session_uri,
        EzagentPluginLoom.Prompts.loom_seed_source(),
        "初始页"
      )

      # Best-effort one-way Feishu mirror (gated by FEISHU_MIRROR_ENABLED=1),
      # mirroring EzagentPluginLoom.Bootstrap — so a UI-created loom session
      # also mirrors to the demo Feishu group, not just the script path.
      # Failure must NOT fail instantiate; idempotent on re-add.
      maybe_bind_feishu(session_uri)
      {:ok, [session_uri]}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # 2026-06-01 redesign: emit a system `<span type="page_update">` chat message
  # so the loom-view bridge picks it up via `getHistory()` on first open. Sender
  # = `system://session-internal` (same principal LoomSession uses for joins);
  # `mentions = []` (session-wide announcement, not addressed to anyone).
  # Best-effort; failures logged + swallowed.
  defp seed_loom_source(%URI{} = session_uri, source, summary)
       when is_binary(source) and is_binary(summary) do
    body =
      EzagentPluginLoom.Span.span("page_update", %{
        "source" => source,
        "summary" => summary
      })

    sender = Ezagent.SystemPrincipal.uri("session-internal")
    msg = Ezagent.Message.new(sender, %{text: body, attachments: []}, mentions: [])
    target = Ezagent.URI.parse!("#{URI.to_string(session_uri)}?action=chat.send")

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

  defp join_members(%URI{} = session_uri, members) when is_list(members) do
    target = Ezagent.URI.parse!("#{URI.to_string(session_uri)}?action=chat.join")

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
    {:ok, Ezagent.URI.parse!(s)}
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

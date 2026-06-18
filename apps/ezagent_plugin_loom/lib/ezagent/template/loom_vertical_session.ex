defmodule Ezagent.PluginLoom.Template.LoomVerticalSession do
  @moduledoc """
  `session.loom_vertical` Template Class — **loom as a socialware vertical** (P0).

  Unlike the legacy `Ezagent.PluginLoom.Template.LoomSession` (which spawns a
  bare chat Session + a standalone loom agent team via `Team.ensure_team`), this
  template materializes the **unified domain-owned `Ezagent.Entity.Session`** Kind
  with the **socialware behavior subset** (`{Session, Turn, Surface, Publisher}`)
  — so Turn/Surface are ACTIVE on the instance. The page lives in the `:surface`
  slice (versions + `approved` pointer); orchestration runs through `Turn`.

  Mirrors `EzagentPluginAdvisor.Template.AdvisorSession` (the canonical vertical
  pattern, P5-1b collapse). See `docs/loom-port/SOCIALWARE-VERTICAL.md`.

  This is the strangler entry for the re-architecture — it runs ALONGSIDE the
  legacy `session.loom` so the new substrate path is independently testable.
  Later phases add the member agents (builder/workers) that Turn dispatches to,
  the consumer side (CustomerFeed), and finally cut `session.loom` over to this.

  ## Template data

      %{
        "class" => "session.loom_vertical",   # required
        "session_name" => "demo",              # required → session://<ws>/loom/demo
        "operator_uri" => "entity://<ws>/user/<name>"  # optional creator/operator
      }
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  alias Ezagent.Entity.Session
  alias Ezagent.{Invocation, KindRegistry, SystemPrincipal, WorkspaceRegistry}

  @impl Ezagent.Kind.Template
  def template_name, do: "session.loom_vertical"

  @impl Ezagent.Kind.Template
  def validate(%{"class" => "session.loom_vertical", "session_name" => n})
      when is_binary(n) and n != "",
      do: :ok

  def validate(%{"class" => "session.loom_vertical"}),
    do: {:error, :missing_or_empty_session_name}

  def validate(%{"class" => other}), do: {:error, {:wrong_class, other}}
  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"session_name" => session_name} = tmpl, %URI{} = workspace_uri) do
    ws = Ezagent.URI.workspace_name!(workspace_uri)
    session_uri = Ezagent.URI.session(ws, :loom, session_name)

    case ensure_session(session_uri) do
      {:ok, fresh?} ->
        with :ok <- WorkspaceRegistry.bind(session_uri, workspace_uri),
             {:ok, _} <-
               Ezagent.Behavior.Session.system_set_working_copy(
                 session_uri,
                 working_copy(session_name, tmpl)
               ),
             :ok <- maybe_join_operator(session_uri, tmpl) do
          {:ok, [session_uri], %{fresh?: fresh?, vertical: :loom}}
        else
          {:error, _reason} = error ->
            cleanup_if_fresh(session_uri, fresh?)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # ── unified Session spawn (the load-bearing line) ──

  defp ensure_session(session_uri) do
    case Ezagent.Kind.spawn(Session, %{
           uri: session_uri,
           behaviors: Session.socialware_behaviors()
         }) do
      {:ok, _pid} -> {:ok, true}
      {:error, {:already_started, _pid}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp working_copy(session_name, tmpl) do
    %{
      "class" => template_name(),
      "vertical" => "loom",
      "session_name" => session_name,
      "operator_uri" => tmpl |> Map.get("operator_uri", "") |> to_string()
    }
  end

  # ── operator/creator (optional in P0) ──

  defp maybe_join_operator(session_uri, %{"operator_uri" => uri_str})
       when is_binary(uri_str) and uri_str != "" do
    case parse_user_uri(uri_str) do
      {:ok, operator_uri} ->
        with :ok <- ensure_user(operator_uri),
             {:ok, _} <- join_operator(session_uri, operator_uri) do
          :ok
        end

      {:error, _} = error ->
        error
    end
  end

  defp maybe_join_operator(_session_uri, _tmpl), do: :ok

  defp parse_user_uri(uri_str) do
    uri = Ezagent.URI.new!(uri_str)

    if uri.scheme == "entity" and Ezagent.URI.type?(uri, :user) do
      {:ok, uri}
    else
      {:error, {:invalid_operator_uri, uri_str}}
    end
  rescue
    ArgumentError -> {:error, :bad_operator_uri}
  end

  # Mirror `EzagentPluginLoom.TempUser`: a regular `Ezagent.Entity.User`, created
  # via `Users.create/3` then registered live via `SpawnRegistry.spawn/1` (join
  # requires the member Kind to be registered).
  defp ensure_user(%URI{} = user_uri) do
    case KindRegistry.lookup(user_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        _ = Ezagent.Users.create(user_uri, nil, [])

        case Ezagent.SpawnRegistry.spawn(user_uri) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:operator_spawn_failed, reason}}
        end
    end
  end

  defp join_operator(session_uri, operator_uri) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(session_uri, :session, :join),
      mode: :call,
      args: %{member: operator_uri, role_name: "operator", in_session_template: true},
      ctx: %{
        caller: SystemPrincipal.uri("template-materialize"),
        caps: "template-materialize" |> SystemPrincipal.uri() |> SystemPrincipal.caps(),
        reply: {:caller_inbox, self()}
      }
    })
    |> case do
      :ok -> {:ok, :joined}
      {:ok, _} = ok -> ok
      {:error, _reason} = error -> error
    end
  end

  defp cleanup_if_fresh(_session_uri, false), do: :ok

  defp cleanup_if_fresh(session_uri, true) do
    _ = Ezagent.Kind.terminate(session_uri)
    :ok
  end
end

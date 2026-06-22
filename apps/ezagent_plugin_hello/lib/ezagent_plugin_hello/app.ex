defmodule EzagentPluginHello.App do
  @moduledoc """
  Instantiate a hello socialware app: a `public_view` session whose member is a
  hello builder agent. This is the Phase-0 in-code author flow (the world-UI
  "New hello app" flow is Phase 2); it mirrors the socialware local-E2E recipe
  + adds the builder member.

  After `ensure_app/2` an anonymous visitor at
  `/socialware/chat?session_uri=session://<ws>/hello/<name>` can view the page
  the builder generates; `generate_now/2` (or a user chat message to the session)
  drives a generation turn.
  """

  alias Ezagent.{Capability, Invocation, WorkspaceRegistry}
  alias Ezagent.Entity.{HelloBuilder, Session, SessionTemplate, User}
  alias Ezagent.Behavior.Session.ConfigActions

  @doc """
  Idempotently create the hello app: a `public_view` SessionTemplate, a live
  socialware `Session` bound to it, and a joined `HelloBuilder` member. Returns
  `{:ok, session_uri, builder_uri}`.
  """
  @spec ensure_app(String.t(), String.t()) :: {:ok, URI.t(), URI.t()} | {:error, term()}
  def ensure_app(ws, name) when is_binary(ws) and is_binary(name) do
    session_uri = Ezagent.URI.session(ws, :hello, name)
    builder_uri = Ezagent.URI.entity(ws, :agent, "hello_#{name}")
    workspace = Capability.workspace_of(session_uri)

    with {:ok, tmpl} <-
           SessionTemplate.persist_version_as_system(
             %{name: "hello-#{name}", public_view: true},
             ws
           ),
         :ok <-
           spawn_kind(Session, %{uri: session_uri, behaviors: Session.socialware_behaviors()}),
         :ok <- bind_workspace(session_uri, workspace),
         {:ok, _} <-
           ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl}),
         :ok <- spawn_kind(HelloBuilder, %{uri: builder_uri}),
         {:ok, _} <- join(session_uri, builder_uri),
         :ok <- grant_orchestrator_caps(builder_uri, session_uri) do
      {:ok, session_uri, builder_uri}
    end
  end

  @doc "Synchronously run one generation turn (seed/test convenience)."
  @spec generate_now(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_now(%URI{} = session_uri, prompt) when is_binary(prompt) do
    EzagentPluginHello.Generator.generate(session_uri, prompt)
  end

  # --- internals --------------------------------------------------------

  # Equip the builder as the session ORCHESTRATOR (Phase 1): grant the
  # scope-bounded delegation caps a real orchestrator holds — `{:within_session,
  # S}` (cap #1) + `{:spawned_by, orchestrator}` (cap #2) + delegable Template
  # caps — via the same `Orchestrator.Caps` mechanism cc orchestrators use. The
  # `{:within_session, S}` cap is what `Orchestrator.Tools.add_managed_member`
  # preflights before spawning workers, so without this the builder cannot fan
  # out. Owner/granter = the admin entity (the in-code creator of this app); a
  # per-creator owner is a follow-up.
  defp grant_orchestrator_caps(builder_uri, session_uri) do
    Ezagent.Entity.Session.grant_orchestrator_scoped_caps(
      builder_uri,
      session_uri,
      User.admin_uri()
    )
  end

  # Idempotent workspace bind — re-instantiating an existing hello app (the
  # Template Class create path) hits an already-bound session; that is success,
  # not an error.
  defp bind_workspace(session_uri, workspace) do
    case Ezagent.WorkspaceRegistry.bind(session_uri, workspace) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:already_registered, _} -> :ok
      other -> other
    end
  end

  defp spawn_kind(kind_module, args) do
    case Ezagent.Kind.spawn(kind_module, args) do
      {:ok, _pid} -> :ok
      # Already-live Kind (re-instantiate of an existing app) is success.
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_registered, _uri}} -> :ok
      {:error, _} = err -> err
    end
  end

  defp join(session_uri, member_uri) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: %{member: member_uri, role_name: "builder"},
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end
end

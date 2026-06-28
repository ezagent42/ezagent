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
  alias Ezagent.Session.InstallCatalog

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
    content = %{name: "hello-#{name}", public_view: true, installs: ["socialware"]}

    with {:ok, tmpl} <-
           SessionTemplate.persist_version_as_system(content, ws),
         {:ok, behaviors} <- InstallCatalog.behavior_set_for_template(content),
         :ok <-
           spawn_kind(Session, %{uri: session_uri, behaviors: behaviors}),
         :ok <- bind_workspace(session_uri, workspace),
         {:ok, _} <-
           ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl}),
         :ok <- spawn_kind(HelloBuilder, %{uri: builder_uri}),
         {:ok, _} <- join(session_uri, builder_uri) do
      {:ok, session_uri, builder_uri}
    end
  end

  @doc "Synchronously run one generation turn (seed/test convenience)."
  @spec generate_now(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_now(%URI{} = session_uri, prompt) when is_binary(prompt) do
    EzagentPluginHello.Generator.generate(session_uri, prompt)
  end

  # --- internals --------------------------------------------------------

  # Idempotent workspace bind — re-instantiating an existing hello app (the
  # Template Class create path) hits an already-bound session; that is success,
  # not an error.
  defp bind_workspace(session_uri, workspace) do
    # WorkspaceRegistry.bind/2 is an idempotent ETS upsert that always returns
    # :ok — re-instantiating an existing hello app re-binds harmlessly. (Earlier
    # this matched {:already_registered, _} error tuples the registry no longer
    # returns; those clauses were dead under the current API.)
    WorkspaceRegistry.bind(session_uri, workspace)
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

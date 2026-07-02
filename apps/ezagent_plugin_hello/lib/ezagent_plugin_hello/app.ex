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
  alias Ezagent.Behavior.Session.ConfigActions
  alias Ezagent.Entity.{HelloBuilder, HelloConcierge, Session, SessionTemplate, User}
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}

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
    socialware_name = "hello-#{name}"
    content = %{name: socialware_name, installs: [socialware_name]}

    with {:ok, _} <- seed_hello_definition(ws, socialware_name),
         {:ok, tmpl} <- SessionTemplate.persist_version_as_system(content, ws),
         {:ok, behaviors} <- Installation.behavior_set_for_template(content, workspace),
         :ok <-
           spawn_kind(Session, %{uri: session_uri, behaviors: behaviors}),
         :ok <- bind_workspace(session_uri, workspace),
         :ok <-
           Installation.install_template_installs(
             session_uri,
             workspace,
             content,
             User.admin_uri()
           ),
         {:ok, _} <-
           ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl}),
         :ok <- spawn_kind(HelloBuilder, %{uri: builder_uri}),
         {:ok, _} <- join(session_uri, builder_uri),
         # The read-only concierge (non-owner visitors talk to it; owner talks to
         # the builder). Best-effort — a concierge hiccup must not fail app create.
         _ <- ensure_session_concierge(session_uri) do
      {:ok, session_uri, builder_uri}
    end
  end

  @doc """
  Idempotently ensure a hello session has its read-only `HelloConcierge` member
  (`entity://<ws>/agent/concierge_<name>`), joined with role `"concierge"`. This
  is the agent non-owner visitors' messages are routed to (see
  `EzagentWeb.Socialware.SessionFeedChannel` — owner → builder, others →
  concierge). No-op (`:ignore`) for a session with no Surface (not a hello / page
  session); tolerant of an already-joined concierge.
  """
  @spec ensure_session_concierge(URI.t()) :: {:ok, URI.t()} | :ignore | {:error, term()}
  def ensure_session_concierge(%URI{} = session_uri) do
    if page_session?(session_uri) do
      ws = Ezagent.URI.workspace_name!(session_uri)
      name = session_name(session_uri)
      concierge_uri = Ezagent.URI.entity(ws, :agent, "concierge_#{name}")

      with :ok <- spawn_kind(HelloConcierge, %{uri: concierge_uri}) do
        _ = join_as(session_uri, concierge_uri, "concierge")
        {:ok, concierge_uri}
      end
    else
      :ignore
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Idempotently ensure a hello session has its `HelloBuilder` member (so `@hello`
  page-editing works). Needed for a session created from a PUBLISHED hello
  template via the substrate's generic create path — that path installs the
  socialware behaviours + seeds the captured page, but (unlike `ensure_app/2` /
  the `session.hello` class) does NOT spawn the per-session builder.

  The builder URI matches the `@hello` mention-routing convention
  (`entity://<ws>/agent/hello_<session-name>`), so the new session's `@hello`
  resolves to it. No-op (`:ignore`) for a session with no Surface (not a hello /
  page session); tolerant of an already-joined builder.
  """
  @spec ensure_session_builder(URI.t()) :: {:ok, URI.t()} | :ignore | {:error, term()}
  def ensure_session_builder(%URI{} = session_uri) do
    if page_session?(session_uri) do
      ws = Ezagent.URI.workspace_name!(session_uri)
      name = session_name(session_uri)
      builder_uri = Ezagent.URI.entity(ws, :agent, "hello_#{name}")

      with :ok <- spawn_kind(HelloBuilder, %{uri: builder_uri}) do
        _ = join(session_uri, builder_uri)
        {:ok, builder_uri}
      end
    else
      :ignore
    end
  rescue
    e -> {:error, e}
  end

  # A hello/page session carries a `:surface` slice; a plain chat session does
  # not, so we never attach a builder where there's no page to edit.
  defp page_session?(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, slice} when is_map(slice) and map_size(slice) > 0 -> true
      _ -> false
    end
  end

  defp session_name(session_uri) do
    session_uri.path |> to_string() |> String.split("/", trim: true) |> List.last()
  end

  @doc "Synchronously run one generation turn (seed/test convenience)."
  @spec generate_now(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_now(%URI{} = session_uri, prompt) when is_binary(prompt) do
    EzagentPluginHello.Generator.generate(session_uri, prompt)
  end

  # --- internals --------------------------------------------------------

  defp seed_hello_definition(ws, name) do
    DefinitionRegistry.seed_definition_if_absent(
      %{
        name: name,
        bases: [
          Ezagent.Behavior.Session,
          Ezagent.Behavior.Publisher.SessionImpl
        ],
        shape: [
          Ezagent.Behavior.Turn,
          Ezagent.Behavior.Surface
        ],
        members: [],
        routing_rules: [],
        prompt_templates: %{},
        legends: %{},
        adapters: [%{adapter_id: "web_feed", role: :customer, config: %{}}],
        visibility_policy: %{publish_policy: :auto, web_anon_access: true}
      },
      workspace_uri: Ezagent.URI.workspace(ws),
      actor_uri: User.admin_uri()
    )
  end

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

  defp join(session_uri, member_uri), do: join_as(session_uri, member_uri, "builder")

  defp join_as(session_uri, member_uri, role_name) when is_binary(role_name) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: %{member: member_uri, role_name: role_name},
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end
end

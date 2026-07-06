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

  require Logger

  alias Ezagent.{Capability, Invocation, Workspace, WorkspaceRegistry}
  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}

  # hello's two agents are ROLES on the unified `Entity.Agent` hosted by the
  # `native` flavor (Principle 1 — an agent type is a role × flavor, never its own
  # Kind). Recipes registered in `EzagentPluginHello.Application.roles/0`.
  @native_flavor "native"
  @hello_flavor "hello"
  @orch_role "hello.orchestrator"
  @builder_role "hello.builder"
  @concierge_role "hello.concierge"

  @doc """
  Idempotently create the hello app: a `public_view` SessionTemplate, a live
  socialware `Session` bound to it, and a joined ORCHESTRATOR member (a
  `hello.orchestrator` role × `native` flavor agent — the invisible front desk).
  The `builder` + `concierge` are spawned ON DEMAND by the orchestrator on the
  first owner build / first question, not eagerly here. Returns
  `{:ok, session_uri, orchestrator_uri}`.
  """
  @spec ensure_app(String.t(), String.t(), keyword()) ::
          {:ok, URI.t(), URI.t()} | {:error, term()}
  def ensure_app(ws, name, opts \\ []) when is_binary(ws) and is_binary(name) do
    session_uri = Ezagent.URI.session(ws, :hello, name)
    workspace = Capability.workspace_of(session_uri)
    socialware_name = "hello-#{name}"
    content = %{name: socialware_name, installs: [socialware_name]}

    with {:ok, _} <- seed_hello_definition(ws, socialware_name),
         # SPEC §4.4 (Decision A) — the anon-homesite create path is the SECOND
         # production behavior_set_for_template/2 call site and is NOT retired in
         # P0, so it MUST apply the SAME freeze helper: resolve the hello def to
         # its current revision and bake the pin into the content's installs
         # BEFORE persisting the template, resolving behaviors, and writing install
         # records. Without this a later hello publish would silently change the
         # running flagship — the surface the pin matters most for.
         {:ok, content} <- Installation.freeze_template_installs(content, workspace),
         # SPEC §7.2 (O-1) — DERIVE the page owner from the hello def's
         # `owner_policy` instead of hard-coding `User.admin_uri()`. The def is
         # `:fixed` to the system admin (D-5, anon homesite), so this resolves to
         # the same admin owner — now as DATA. The caller fallback (`:installer`)
         # is admin here (this path is admin-authored).
         {:ok, owner_uri} <-
           Installation.owner_uri_for_template(content, workspace, User.admin_uri()),
         {:ok, tmpl} <- SessionTemplate.persist_version_as_system(content, ws),
         {:ok, behaviors} <- Installation.behavior_set_for_template(content, workspace),
         :ok <-
           spawn_kind(Session, %{
             uri: session_uri,
             # hello apps are operator-built; the page OWNER (the one the
             # orchestrator routes to the builder) comes from the def's `:fixed`
             # `owner_policy`. Without an owner the session is ownerless and every
             # message falls to the concierge.
             owner_uri: owner_uri,
             behaviors: behaviors
           }),
         :ok <- bind_workspace(session_uri, workspace),
         :ok <-
           Installation.install_template_installs(
             session_uri,
             workspace,
             content,
             User.admin_uri()
           ),
         {:ok, _} <-
           ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl}) do
      orch_uri = orchestrator_uri(session_uri)

      ensure_orchestrator(
        session_uri,
        workspace,
        name,
        Keyword.get(opts, :defer_orchestrator, false)
      )

      {:ok, session_uri, orch_uri}
    end
  end

  # Create + join the orchestrator. `defer?: true` runs it OFF this process in a
  # supervised Task — required when `ensure_app` runs INSIDE the workspace Kind
  # process (the `session.hello` Template Class instantiate is called from
  # `Workspace.handle_create_session`): `create_role_agent` dispatches a `:call` to
  # that same workspace, which would `:calling_self`-deadlock. Off-process callers
  # (demo seed Task, tests) pass `defer?: false` for a synchronous, race-free create.
  defp ensure_orchestrator(session_uri, workspace, name, true = _defer?) do
    Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
      ensure_orchestrator(session_uri, workspace, name, false)
    end)

    :ok
  end

  defp ensure_orchestrator(session_uri, workspace, name, false = _defer?) do
    case create_role_agent(workspace, "orch_#{name}", @orch_role, @hello_flavor) do
      {:ok, orch_uri} ->
        _ = join_as(session_uri, orch_uri, "orchestrator")
        :ok

      err ->
        Logger.warning(
          "hello: orchestrator create failed for #{URI.to_string(session_uri)}: #{inspect(err)}"
        )

        err
    end
  end

  @doc """
  Idempotently ensure a hello session has its `HelloOrchestrator` front-desk member
  (`entity://<ws>/agent/orch_<name>`), joined with role `"orchestrator"`. This is
  the agent ALL user messages are routed to (see
  `EzagentWeb.Socialware.SessionFeedChannel`); it then routes each message to the
  builder / concierge. Needed for a hello session created BEFORE the orchestrator
  model (migration) or via the published-template path. No-op (`:ignore`) for a
  session with no Surface (not a hello / page session).
  """
  @spec ensure_session_orchestrator(URI.t()) :: {:ok, URI.t()} | :ignore | {:error, term()}
  def ensure_session_orchestrator(%URI{} = session_uri) do
    if page_session?(session_uri) do
      ws = Ezagent.URI.workspace_name!(session_uri)
      name = session_name(session_uri)
      workspace = Ezagent.URI.workspace(ws)

      with {:ok, orch_uri} <-
             create_role_agent(workspace, "orch_#{name}", @orch_role, @hello_flavor) do
        _ = join_as(session_uri, orch_uri, "orchestrator")
        {:ok, orch_uri}
      end
    else
      :ignore
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Idempotently ensure the read-only `concierge` agent EXISTS
  (`entity://<ws>/agent/concierge_<name>`) — created on demand by the orchestrator
  when it routes a question. It is NOT joined as a chat member: only the
  orchestrator is a chat member (so a message fans out to it alone and nothing
  double-acts); the concierge is purely the identity its reply is attributed to
  (posted via admin-authority `TurnDriver`, not via its membership). No-op
  (`:ignore`) for a session with no Surface (not a hello / page session).
  """
  @spec ensure_session_concierge(URI.t()) :: {:ok, URI.t()} | :ignore | {:error, term()}
  def ensure_session_concierge(%URI{} = session_uri) do
    if page_session?(session_uri) do
      ws = Ezagent.URI.workspace_name!(session_uri)
      name = session_name(session_uri)
      create_role_agent(Ezagent.URI.workspace(ws), "concierge_#{name}", @concierge_role)
    else
      :ignore
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Idempotently ensure the `builder` agent EXISTS
  (`entity://<ws>/agent/hello_<name>`) — created on demand by the orchestrator when
  it routes a page-build request. Like the concierge it is NOT joined as a chat
  member (the orchestrator drives page generation via admin-authority
  `TurnDriver`); the agent exists only as the `@hello` identity / for operator
  display. No-op (`:ignore`) for a session with no Surface.
  """
  @spec ensure_session_builder(URI.t()) :: {:ok, URI.t()} | :ignore | {:error, term()}
  def ensure_session_builder(%URI{} = session_uri) do
    if page_session?(session_uri) do
      ws = Ezagent.URI.workspace_name!(session_uri)
      name = session_name(session_uri)
      create_role_agent(Ezagent.URI.workspace(ws), "hello_#{name}", @builder_role)
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

  @doc "The orchestrator agent URI for a hello session (`entity://<ws>/agent/orch_<name>`)."
  @spec orchestrator_uri(URI.t()) :: URI.t()
  def orchestrator_uri(%URI{} = session_uri), do: agent_uri(session_uri, "orch_")

  @doc "The builder agent URI for a hello session (`entity://<ws>/agent/hello_<name>`)."
  @spec builder_uri(URI.t()) :: URI.t()
  def builder_uri(%URI{} = session_uri), do: agent_uri(session_uri, "hello_")

  @doc "The concierge agent URI for a hello session (`entity://<ws>/agent/concierge_<name>`)."
  @spec concierge_uri(URI.t()) :: URI.t()
  def concierge_uri(%URI{} = session_uri), do: agent_uri(session_uri, "concierge_")

  # The single canonical hello agent-URI derivation (session → entity URI), so the
  # prefix convention lives in ONE place (behaviors + Router call these helpers).
  defp agent_uri(%URI{} = session_uri, prefix) do
    ws = Ezagent.URI.workspace_name!(session_uri)
    Ezagent.URI.entity(ws, :agent, "#{prefix}#{session_name(session_uri)}")
  end

  @doc "Synchronously run one generation turn (seed/test convenience)."
  @spec generate_now(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_now(%URI{} = session_uri, prompt) when is_binary(prompt) do
    EzagentPluginHello.Generator.generate(session_uri, prompt)
  end

  # --- internals --------------------------------------------------------

  @doc "The hello socialware Definition attrs for a given socialware name (testable)."
  @spec hello_definition_attrs(String.t()) :: map()
  def hello_definition_attrs(name) when is_binary(name) do
    %{
      name: name,
      bases: [
        Ezagent.ActionSet.Session,
        Ezagent.ActionSet.Publisher.SessionImpl
      ],
      shape: [
        Ezagent.ActionSet.Turn,
        Ezagent.ActionSet.Surface
      ],
      roles: [
        %{role_name: "orchestrator", fill: :agent, recipe: "hello.orchestrator", flavor: "hello"},
        %{role_name: "builder", fill: :agent, recipe: "hello.builder", flavor: "native"},
        %{role_name: "concierge", fill: :agent, recipe: "hello.concierge", flavor: "native"}
      ],
      routing_rules: [
        %{
          "matcher" => %{"type" => "always"},
          "receivers" => ["orchestrator"],
          "rule_set" => "default",
          "position" => 0
        }
      ],
      prompt_templates: %{},
      legends: %{},
      adapters: [%{adapter_id: "external_feed", role: :customer, config: %{}}],
      visibility_policy: %{publish_policy: :auto, web_anon_access: true},
      owner_policy: %{type: :installer}
    }
  end

  defp seed_hello_definition(ws, name) do
    DefinitionRegistry.seed_definition_if_absent(
      hello_definition_attrs(name),
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

  # Create (or revive) a hello agent as a ROLE × flavor on the unified
  # `Entity.Agent` (RF-5a role-create path — `Workspace.create_agent`). The role's
  # behaviors + `requested_caps` come from the recipe (`Application.roles/0`); the
  # flavor's `CapPolicy.for_recipe/1` authorizes exactly those caps on the `:agent`
  # axis. The resulting `entity://<ws>/agent/<name>` is the member URI. The
  # ORCHESTRATOR uses the `"hello"` flavor (its in-process AgentBridge adapter
  # receives chat); the builder/concierge use `"native"` (they never receive chat —
  # the orchestrator drives their work via admin-authority `TurnDriver`). Idempotent:
  # a re-instantiate hits an already-live agent — that is success.
  defp create_role_agent(
         %URI{scheme: "workspace"} = workspace,
         name,
         role,
         flavor \\ @native_flavor
       ) do
    ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Capability.admin_genesis_cap()])
    }

    args = %{flavor: flavor, name: name, role: role, cwd: "", with_pty: false}

    case Workspace.create_agent(workspace, args, ctx) do
      {:ok, %{agent_uri: agent_uri}} ->
        {:ok, agent_uri}

      # Re-instantiate of an existing hello app: the role agent is already there.
      {:error, {:already_exists, _uri}} ->
        {:ok, Ezagent.URI.entity(Ezagent.URI.workspace_name!(workspace), :agent, name)}

      {:error, _} = err ->
        err
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

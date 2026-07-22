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

  alias Ezagent.{Capability, WorkspaceRegistry}
  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.Derivation
  alias EzagentPluginHello.Members

  @doc """
  Idempotently create the hello app AND install its declared team — the composite
  used by boot seeding, tests and operator flows. `create_app/3` (session +
  config, owner-only) then `SessionCreator.install_session_socialware/1` (the
  agent transaction).

  Returns `{:ok, session_uri, front_desk_uri}`, resolved by role
  (`Members.role_uri/2`), NOT the retired `orch_<name>` URI convention.

  **Do NOT call this from a session-create dispatch** — `HelloSession.instantiate/3`
  calls `create_app/3` and lets `Workspace.create_session` fire the install
  transaction afterwards (rev6 / #912; see `create_app/3`).
  """
  @spec ensure_app(String.t(), String.t(), keyword()) ::
          {:ok, URI.t(), URI.t()} | {:error, term()}
  def ensure_app(ws, name, opts \\ []) when is_binary(ws) and is_binary(name) do
    with {:ok, %URI{} = session_uri} <- create_app(ws, name, opts),
         # `{:ok, summary}` — a role slot skipped for missing credentials (e.g. the
         # `requires`-pulled cc orchestrator, for a non-admin installer) does NOT
         # fail the app; hello's own roles are credential-less. `resolve_front_desk/1`
         # below is the fail-loud check that the roles hello ACTUALLY needs landed.
         {:ok, _summary} <- SessionCreator.install_session_socialware(session_uri),
         {:ok, front_desk_uri} <- resolve_front_desk(session_uri) do
      {:ok, session_uri, front_desk_uri}
    end
  end

  @doc """
  Create the hello session and its CONFIG — nothing else. Spawns no agent.

  rev6 / #912: a session create — including a Template Class's `instantiate/3` —
  never spawns, waits for, or rolls back on a role member. The declared team
  (`Definition.roles`) is recorded as `member_declarations` on the working copy
  and materialized by the SEPARATE post-create socialware-install transaction,
  which `Workspace.create_session` fires once the owner-only session is durable.

  Before this split, `HelloSession.instantiate/3` → `ensure_app/3` spawned four
  role agents (plus the `requires`-pulled cc orchestrator) INSIDE the
  `workspace.create_session` dispatch — the same coupling that made `default`
  sessions time out. `default` was decoupled by the facade path; `hello` reaches
  create through the Template Class path, which is why it needed its own fix.
  """
  @spec create_app(String.t(), String.t(), keyword()) :: {:ok, URI.t()} | {:error, term()}
  def create_app(ws, name, _opts \\ []) when is_binary(ws) and is_binary(name) do
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
         :ok <- Derivation.record(session_uri, {owner_uri, workspace, tmpl}),
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
         # M-1 owner-bypass removal pairing: every session creator must grant
         # its owner the born-signed tier-1 membership cap before exposing
         # owner-authored content operations.
         :ok <-
           Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(
             session_uri,
             owner_uri
           ),
         :ok <-
           Installation.install_template_installs(
             session_uri,
             workspace,
             content,
             User.admin_uri()
           ),
         # Record the DURABLE declaration (`session_template_uri` +
         # `member_declarations`), not just the template URI: the post-create
         # install transaction reads `member_declarations` to know which role
         # slots to materialize. A bare `system_set_working_copy` would leave the
         # declared team un-installable.
         :ok <- SessionCreator.materialize_template_declaration(session_uri, tmpl, content),
         # CONFIG only — prompts / legends / routing rules. The `Definition.roles`
         # agents are the install transaction's job (see `create_app/3` moduledoc).
         :ok <- SessionCreator.materialize_template_config(session_uri, workspace, content) do
      {:ok, session_uri}
    end
  end

  # Resolve the front-desk member URI by its `role_name` facet (the framework
  # materialization assigns a PLANNED UUID URI — it is NOT derivable from the
  # session name). A missing front-desk after a successful materialize is a
  # fail-loud bug, not a silent nil.
  defp resolve_front_desk(%URI{} = session_uri) do
    case Members.role_uri(session_uri, "front-desk") do
      {:ok, %URI{} = uri} -> {:ok, uri}
      :error -> {:error, {:front_desk_not_materialized, session_uri}}
    end
  end

  @doc "Synchronously run one generation turn (seed/test convenience)."
  @spec generate_now(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_now(%URI{} = session_uri, prompt) when is_binary(prompt) do
    EzagentPluginHello.Generator.generate(session_uri, prompt)
  end

  # --- internals --------------------------------------------------------

  # The platform cc orchestrator requires a real Claude Code binary + bridge
  # infrastructure. In local dev (claude_code backend, no cc plugin bootstrap)
  # the orchestrator activate times out — skip the requires so the session
  # creates without it. Set HELLO_NO_ORCHESTRATOR=0 to force-enable.
  defp hello_requires do
    if System.get_env("HELLO_NO_ORCHESTRATOR", "1") == "0", do: ["orchestrator"], else: []
  end

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
        %{role_name: "front-desk", fill: :agent, recipe: "hello.front-desk", flavor: "hello"},
        %{role_name: "builder", fill: :agent, recipe: "hello.builder", flavor: "native"},
        %{role_name: "concierge", fill: :agent, recipe: "hello.concierge", flavor: "native"},
        %{role_name: "llm", fill: :agent, recipe: "hello.llm", flavor: "curl"},
        %{role_name: "sharer", fill: :agent, recipe: "hello.sharer", flavor: "native"},
        %{role_name: "publisher", fill: :agent, recipe: "hello.publisher", flavor: "native"},
        %{
          role_name: "dispatcher",
          fill: :agent,
          recipe: "hello.dispatcher",
          flavor: "native"
        }
      ],
      routing_rules: [
        %{
          "matcher" => %{"type" => "always"},
          "receivers" => ["front-desk"],
          "rule_set" => "default",
          "position" => 0
        }
      ],
      # M3 #1230: the platform stock cc-orchestrator is auto-installed per-session
      # (A-1 single-instance guarantee). This replaces the retired hello-owned
      # orchestrator stub with the fully-wired cc orchestrator (credentials + tools).
      # Skip in local dev when no cc infrastructure is available (the orchestrator
      # activation times out without a real Claude Code binary).
      requires: hello_requires(),
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

  defp spawn_kind(kind_module, args) do
    # derivation-edge: recorded-by create_app/3 via SessionCreator.Derivation
    case Ezagent.Kind.spawn(kind_module, args) do
      {:ok, _pid} -> :ok
      # Already-live Kind (re-instantiate of an existing app) is success.
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_registered, _uri}} -> :ok
      {:error, _} = err -> err
    end
  end
end

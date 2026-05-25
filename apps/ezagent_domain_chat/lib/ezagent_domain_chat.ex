defmodule EzagentDomainChat do
  @moduledoc """
  Top-level facade for the chat plugin (Phase 3b-step 1).

  Provides `create_session/2` to dynamically spawn additional Session
  Kinds at runtime (admin LV / mix task / external API / first-login
  wizard can call this).

  ## PR-J (Phase 8c, Allen 2026-05-20)

  The previous `:main_is_static` restriction was removed. `session://default/system/main`
  is no longer a hardcoded static supervisor child of
  `EzagentDomainChat.Application` — it now goes through the same code
  path as every other session, created by the first-login wizard. The
  test environment seeds it via this same facade in
  `EzagentDomainChat.Application` (test-only branch).

  `create_session/2` is the canonical session-creation API: it spawns
  the Kind, binds it to the creator's workspace (derived structurally
  from the caller's entity URI per SPEC v3 §3.3), and joins the
  creator. Idempotent for same short_name — re-call returns the
  existing URI + (re)joins creator.
  """

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Entity.{Session, User}

  @doc """
  Spawn a new Session Kind under `EzagentDomainChat.SessionSupervisor`,
  bind it to the creator's workspace, and join `creator_uri` to it.

  SPEC v3 §3.6 (Phase 9 PR-7) — sessions are
  `session://<template>/<workspace>/<name>`. `short_name` becomes the
  `<name>` segment. The default template is `default`. The workspace
  is **derived structurally** from `creator_uri`
  (`Ezagent.URI.entity_workspace_uri/1`) — no silent global fallback
  per SPEC #324. Callers needing a different workspace can pass
  `opts[:workspace_uri]` explicitly (e.g. cross-workspace admin
  flows). `opts[:template_name]` overrides the default template.

  Returns `{:ok, session_uri}` on success, `{:error, reason}` on:
  - `{:already_registered, _}` — session URI already in KindRegistry
  - other DynamicSupervisor errors propagated as-is

  Raises `ArgumentError` if neither `creator_uri` nor
  `opts[:workspace_uri]` is supplied (a `nil` creator with no explicit
  workspace cannot be assigned a workspace structurally).

  Idempotent re-spawn of same short_name returns `{:ok, existing_uri}`
  (via `{:already_started, pid}` → reuse pid).
  """
  @spec create_session(String.t(), URI.t() | nil, keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def create_session(short_name, creator_uri \\ nil, opts \\ [])

  def create_session(short_name, creator_uri, opts)
      when is_binary(short_name) and short_name != "" do
    workspace_uri =
      case Keyword.fetch(opts, :workspace_uri) do
        {:ok, ws} ->
          ws

        :error ->
          case creator_uri do
            %URI{scheme: "entity"} = uri ->
              Ezagent.URI.entity_workspace_uri(uri)

            _ ->
              raise ArgumentError,
                    "EzagentDomainChat.create_session/3 requires either a non-nil " <>
                      "entity creator_uri (to derive workspace structurally) or " <>
                      "an explicit opts[:workspace_uri]. Got creator_uri=" <>
                      "#{inspect(creator_uri)}, opts=#{inspect(opts)}."
          end
      end

    template_name = Keyword.get(opts, :template_name, "default")
    workspace_name = workspace_name_of!(workspace_uri)

    session_uri =
      URI.new!("session://#{template_name}/#{workspace_name}/#{short_name}")

    # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
    # Session Kind declares EzagentDomainChat.SessionSupervisor via
    # supervisor/0 — destination preserved.
    result = Ezagent.Kind.spawn(Session, %{uri: session_uri})

    case result do
      {:ok, _pid} ->
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
        :ok = join_creator(session_uri, creator_uri || User.admin_uri())
        {:ok, session_uri}

      # `:already_started` = same child spec already in supervisor's children
      # `:already_registered` = Kind.Server.init crashed on KindRegistry.put_new
      # conflict (URI claimed by another pid, possibly outside this supervisor).
      # Both indicate "session exists" — return success + re-bind workspace
      # (idempotent ETS overwrite) + re-attempt join (cast is idempotent on
      # members map).
      {:error, {:already_started, _pid}} ->
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
        :ok = join_creator(session_uri, creator_uri || User.admin_uri())
        {:ok, session_uri}

      {:error, {:already_registered, _}} ->
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
        :ok = join_creator(session_uri, creator_uri || User.admin_uri())
        {:ok, session_uri}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_session(_short_name, _creator, _opts), do: {:error, :short_name_required}

  # workspace://<name> → "<name>". Raises ArgumentError if the URI
  # isn't a bare workspace URI (helps catch passing entity / session
  # URIs by accident).
  defp workspace_name_of!(%URI{scheme: "workspace", host: name}) when is_binary(name),
    do: name

  defp workspace_name_of!(other),
    do: raise(ArgumentError, "expected %URI{scheme: \"workspace\"}, got: #{inspect(other)}")

  @doc """
  Return all known Session URIs (KindRegistry session:// entries),
  including main + all dynamically-created sessions. Used by LV
  sidebar render.
  """
  @spec list_sessions :: [URI.t()]
  def list_sessions do
    KindRegistry.list_all()
    |> Enum.filter(fn {uri_str, _pid} -> String.starts_with?(uri_str, "session://") end)
    |> Enum.map(fn {uri_str, _pid} -> URI.new!(uri_str) end)
    |> Enum.sort_by(&URI.to_string/1)
  end

  defp join_creator(session_uri, creator_uri) do
    # PR-M (Allen 2026-05-20) — `chat.join` requires the member's Kind
    # alive in KindRegistry (see Behavior.Chat.invoke(:join) — returns
    # `{:error, {:member_not_registered, _}}` if absent). In production
    # the login path already calls `Ezagent.Entity.ensure_spawned/1`
    # before the wizard reaches create_session. For mix tasks /
    # boot-time test seeds, the test-env admin Kind seed in
    # `EzagentDomainIdentity.Application` covers admin. Demand-spawn
    # any non-admin caller here as belt-and-suspenders — idempotent
    # ({:ok, pid} for already-alive).
    _ = Ezagent.SpawnRegistry.spawn(creator_uri)

    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    _ =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{member: creator_uri},
        # SPEC caps-cleanup-v1 §4.4 — Session creator-join is
        # Session slice-internal (member sync); runs under
        # `system://session-internal` (closed Catalog).
        ctx: %{
          caller: creator_uri,
          caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
          reply: :ignore
        }
      })

    :ok
  end
end

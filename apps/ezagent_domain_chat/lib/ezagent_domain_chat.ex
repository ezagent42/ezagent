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
  `<name>` segment. The workspace is **derived structurally** from
  `creator_uri` (`Ezagent.URI.entity_workspace_uri/1`) — no silent
  global fallback per SPEC #324. Callers needing a different workspace
  can pass `opts[:workspace_uri]` explicitly (e.g. cross-workspace
  admin flows).

  `opts[:template_name]` is **required** per SPEC #366 (Allen
  2026-05-26, `feedback_let_it_crash_no_workarounds`) — the previous
  silent `"default"` fallback was eliminated. The value becomes the
  session URI's class segment (`session://<template_name>/<workspace>/<short_name>`)
  literally — there is NO `Ezagent.TemplateRegistry.lookup/1` resolution
  here; downstream code treats segment 1 as informational. Operators
  pass:
    * `"default"` for the bootstrap session-naming convention (the
      legacy URI shape ~10 test suites assert against), OR
    * Any key from the current workspace's `session_templates` map
      for tenant flows (LV form sources this directly).

  Missing key raises `ArgumentError`.

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

    template_name = require_template_name!(opts)
    workspace_name = workspace_name_of!(workspace_uri)

    session_uri =
      URI.new!("session://#{template_name}/#{workspace_name}/#{short_name}")

    # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
    # Session Kind declares EzagentDomainChat.SessionSupervisor via
    # supervisor/0 — destination preserved.
    #
    # RFC #402 (Allen 2026-05-26) — thread the creator URI as
    # `owner_uri` so `Behavior.Chat.init_slice/1` records it on the
    # session's `:chat` slice. The Generator path
    # (`Session.spawn_from_template/2`) does the same; this brings the
    # direct-create path to parity. Falls back to the bootstrap admin
    # for system-internal session creates (`creator_uri == nil`);
    # `data_owner/1` then routes through `Session.owner/1` so the
    # restart-cap grant flows correctly.
    effective_owner = creator_uri || User.admin_uri()
    result = Ezagent.Kind.spawn(Session, %{uri: session_uri, owner_uri: effective_owner})

    case result do
      {:ok, _pid} ->
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
        :ok = join_creator(session_uri, effective_owner)
        :ok = grant_owner_orchestrator_admin_cap(session_uri, effective_owner, workspace_uri)
        {:ok, session_uri}

      # `:already_started` = same child spec already in supervisor's children
      # `:already_registered` = Kind.Server.init crashed on KindRegistry.put_new
      # conflict (URI claimed by another pid, possibly outside this supervisor).
      # Both indicate "session exists" — return success + re-bind workspace
      # (idempotent ETS overwrite) + re-attempt join (cast is idempotent on
      # members map).
      {:error, {:already_started, _pid}} ->
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
        :ok = join_creator(session_uri, effective_owner)
        :ok = grant_owner_orchestrator_admin_cap(session_uri, effective_owner, workspace_uri)
        {:ok, session_uri}

      {:error, {:already_registered, _}} ->
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
        :ok = join_creator(session_uri, effective_owner)
        :ok = grant_owner_orchestrator_admin_cap(session_uri, effective_owner, workspace_uri)
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

  # SPEC #366 (Allen 2026-05-26) — eliminate the silent `"default"`
  # template-class fallback. Callers MUST pass `:template_name` in opts.
  # The previous code (`Keyword.get(opts, :template_name, "default")`)
  # let LV/CLI/test sites omit the choice and silently land in the
  # `session://default/…` namespace — operationally invisible, blocks
  # tenant-customized session templates per the same reasoning as
  # `feedback_let_it_crash_no_workarounds`.
  defp require_template_name!(opts) do
    case Keyword.fetch(opts, :template_name) do
      {:ok, name} when is_binary(name) and name != "" ->
        name

      {:ok, other} ->
        raise ArgumentError,
              "EzagentDomainChat.create_session/3 requires opts[:template_name] to be " <>
                "a non-empty String, got: #{inspect(other)}. Per SPEC #366 the silent " <>
                "`\"default\"` fallback was removed; pick a class explicitly from the " <>
                "workspace's `session_templates` map (or use `\"default\"` literally " <>
                "for the bootstrap session-naming convention)."

      :error ->
        raise ArgumentError,
              "EzagentDomainChat.create_session/3 requires opts[:template_name] " <>
                "(SPEC #366, Allen 2026-05-26). The previous silent `\"default\"` " <>
                "fallback was removed. Callers — LV forms, CLI tasks, test seeds, " <>
                "bootstrap — must choose a template class explicitly. Examples:\n" <>
                "  * Bootstrap / preserve existing URI shape: `template_name: \"default\"`\n" <>
                "  * Tenant flows: `template_name: <key from workspace.session_templates>`\n" <>
                "Got: opts=#{inspect(opts)}."
    end
  end

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

  # RFC #402 (Allen 2026-05-26) — grant the session creator the
  # `Behavior.OrchestratorAdmin :restart` cap on this session so the
  # `OrchestratorHealthCard` LV renders the Restart button for them
  # (and a non-creator gets nothing). Idempotent: re-calling
  # `create_session/3` for the same session re-enters this path; the
  # cap-equality check inside the helper skips a re-grant when a
  # logically-equal cap row is already on the owner.
  #
  # Mirrors the same grant `Session.spawn_from_template/2` does for
  # the orchestrator-template path; here it covers the direct-create
  # path (`create_session/3` without going through SessionTemplate
  # materialization).
  defp grant_owner_orchestrator_admin_cap(
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    want = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.Behavior.OrchestratorAdmin,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    current = Ezagent.Identity.list_caps_for(owner_uri)

    has_equiv? =
      Enum.any?(current, fn cap ->
        match?(%Ezagent.Capability{}, cap) and
          cap.kind == want.kind and
          cap.behavior == want.behavior and
          cap.instance == want.instance and
          cap.workspace_uri == want.workspace_uri and
          cap.granted_by == want.granted_by
      end)

    if has_equiv? do
      :ok
    else
      target = URI.new!("#{URI.to_string(owner_uri)}?action=identity.grant_cap")
      cap = %{want | granted_at: DateTime.utc_now()}

      _ =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          # SPEC caps-cleanup-v1 §4.4 — granting an ownership cap at
          # session-create time is template-materialization-equivalent;
          # runs under `system://template-materialize` (closed
          # Catalog). Owner stays as caller for provenance.
          ctx: %{
            caller: owner_uri,
            caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
            reply: :ignore
          }
        })

      :ok
    end
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

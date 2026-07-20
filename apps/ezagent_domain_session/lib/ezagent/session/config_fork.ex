defmodule Ezagent.Session.ConfigFork do
  @moduledoc """
  Operator/user-facing entry for the "copy this session's config → new owned
  session" flow (website journey segment 5 — 复制配置，建新会话).

  A user viewing a session one-clicks to **copy that session's configuration**
  into a brand-new session they own: new session, no message history, the
  caller is the owner/tenant. This is the USER-FACING FLOW that wires together
  three pre-existing primitives; it invents no new fork/create mechanism:

    1. **Identify the source SessionTemplate** the in-view session was
       materialized from — read `:session_template_uri` off the session's
       durable `template_working_copy` (`Session.read_template_working_copy/1`).
       The Session Kind is demand-spawned first (a cold session reads back the
       default working copy with `session_template_uri: nil`, which would look
       like "no source" — Advisor #1). A genuine `nil` after the session is live
       means the session never went through a template (a plain system session)
       → fail-closed `{:error, :no_source_template}` (no silent default,
       `feedback_let_it_crash_no_workarounds`).

    2. **Fork that template** via the existing `ActionSet.Template :fork` action
       (`SessionTemplate.fork/3`) with `owner: caller` — a config-only copy
       (Invariant #10) whose `parent_template_uri` points back at the source.

    3. **Create a fresh owned session** from the fork via
       `Ezagent.Workspace.create_session/3` — goes through the dispatch
       chokepoint so the `:create_session` workspace cap (Invariant — CapBAC
       step 5.5) is the REAL authorization gate. The caller becomes the session
       owner; the new session starts with EMPTY chat (Invariant #10 — a
       forked/instantiated session never carries history).

  ## Authorization (cap-checked)

  Two authorities, cleanly separated:

  - **Copy authority (fork the source's config)** — the "you can view this
    session, so you may copy its config" authorization is minted here as a
    caller-scoped `ActionSet.Template` `session_template` cap for the SOURCE
    template's workspace, `granted_by: caller` (the same self-mint the world
    `save_session_template` action does for `SessionTemplate.create/3`). It is
    intra-workspace only (see §Cross-workspace below), so the mint is safe: the
    Invariant-13 cross-workspace dispatch gate blocks it from ever authorizing
    a write into a foreign workspace.
  - **Create authority (own a new session)** — the caller's REAL caps
    (`ctx.caps`) are threaded UNMODIFIED into `create_session`; the
    `:create_session` cap (granted at workspace membership) is the gate. A
    caller without it → `{:error, :unauthorized}`. This is the production gate a
    real user hits — the backend does NOT mint it (the `Ezagent.Session.Participants`
    convention: no persisted-caps read, `cap_check_only_at_chokepoint`).

  ## Cross-workspace (KNOWN LIMIT — surfaced, not silently handled)

  `SessionTemplate.fork/3` derives the new template's workspace from the PARENT
  URI (`ActionSet.Template.fork_session_template/2` ignores any `:workspace`
  override) and the Invariant-13 dispatch gate denies forking a template in a
  foreign workspace. So copying an **official / cross-tenant** session (source
  template in workspace S) into the caller's OWN tenant (workspace U ≠ S) is
  **structurally impossible via `fork`**. This entry fails-closed with
  `{:error, :cross_workspace_copy_unsupported}` rather than producing a
  not-found deeper in `create_session`. The cross-tenant variant needs a
  read-content + create-root-in-caller's-workspace path (workspace-flexible but
  `SessionTemplate.create/3` forces `parent_template_uri: nil`, losing lineage)
  — a follow-up, out of this PR's scope.
  """

  alias Ezagent.Entity.{Session, SessionTemplate}

  @typedoc "Caller dispatch context: the acting entity (becomes the new owner) + its caps."
  @type ctx :: %{required(:caller) => URI.t(), optional(:caps) => Enumerable.t()}

  @typedoc "Result of a successful config fork: the new owned session + the forked template."
  @type result :: %{session_uri: URI.t(), template_uri: URI.t()}

  @doc """
  Copy `session_uri`'s configuration into a new session owned by `ctx.caller`.

  `opts`:
    * `:new_template_name` — name for the forked SessionTemplate. Defaults to
      `"<source-name>-copy-<8hex>"` (unique, so `create_session`'s prefix-scan
      resolves the version just forked, not a stale same-named `@hash`).
    * `:short_name` — the new session's `<name>` URI segment. Defaults to
      `"copy-<8hex>"`.

  Returns `{:ok, %{session_uri: URI.t(), template_uri: URI.t()}}` on success,
  or `{:error, reason}`:
    * `:no_source_template` — the session has no source template (fail-closed).
    * `:cross_workspace_copy_unsupported` — source template lives in a different
      workspace than the caller (see §Cross-workspace in the moduledoc).
    * `:unauthorized` — the caller lacks `:create_session` in the workspace.
    * any fork / create_session failure reason.
  """
  @spec fork_config(URI.t(), ctx(), keyword()) :: {:ok, result()} | {:error, term()}
  def fork_config(session_uri, ctx, opts \\ [])

  def fork_config(%URI{scheme: "session"} = session_uri, %{caller: %URI{} = caller} = ctx, opts)
      when is_list(opts) do
    caps = MapSet.new(Map.get(ctx, :caps, []))

    with {:ok, %URI{} = source_template_uri} <- resolve_source_template(session_uri),
         {:ok, %URI{} = source_ws} <- workspace_of(source_template_uri),
         {:ok, %URI{} = caller_ws} <- entity_workspace(caller),
         :ok <- assert_same_workspace(source_ws, caller_ws),
         new_template_name <- new_template_name(source_template_uri, opts),
         short_name <- short_name(opts),
         # Copy authority — a target-signed concrete fork artifact. The REAL
         # user-facing gate remains `:create_session` below (Advisor #2).
         {:ok, fork_cap} <- issue_fork_cap(source_template_uri, caller),
         fork_caps = MapSet.put(caps, fork_cap),
         {:ok, %URI{} = new_template_uri} <-
           SessionTemplate.fork(source_template_uri, new_template_name,
             caller: caller,
             caps: fork_caps,
             owner: caller
           ),
         {:ok, %URI{} = new_session_uri} <-
           create_session(caller_ws, caller, caps, short_name, new_template_name) do
      {:ok, %{session_uri: new_session_uri, template_uri: new_template_uri}}
    end
  end

  def fork_config(_session_uri, _ctx, _opts), do: {:error, :invalid_arguments}

  # --- source-template resolution ----------------------------------------

  # Advisor #1 — a cold source session reads back the DEFAULT working copy
  # (`session_template_uri: nil`) because `read_template_working_copy/1` only
  # reads a LIVE pid. Demand-spawn first so a genuinely-templated session is
  # not mis-diagnosed as source-less. A `nil` AFTER the session is live is a
  # real "no source" (a plain system session) → fail-closed.
  defp resolve_source_template(%URI{} = session_uri) do
    _ = Ezagent.LocalRuntime.ensure_live(session_uri)

    case Session.read_template_working_copy(session_uri) do
      %{session_template_uri: %URI{} = uri} -> {:ok, uri}
      _ -> {:error, :no_source_template}
    end
  end

  # --- workspace helpers -------------------------------------------------

  defp workspace_of(%URI{} = uri) do
    case Ezagent.Capability.workspace_of(uri) do
      %URI{} = ws -> {:ok, ws}
      :any -> {:error, :cannot_derive_workspace}
    end
  end

  defp entity_workspace(%URI{scheme: "entity"} = uri),
    do: {:ok, Ezagent.URI.entity_workspace_uri(uri)}

  defp entity_workspace(_), do: {:error, :caller_not_entity}

  defp assert_same_workspace(%URI{} = a, %URI{} = b) do
    if URI.to_string(a) == URI.to_string(b) do
      :ok
    else
      {:error, :cross_workspace_copy_unsupported}
    end
  end

  # --- create_session ----------------------------------------------------

  # Through the Workspace `:create_session` dispatch so CapBAC step 5.5
  # (`:create_session` cap) is the gate and the caller becomes the owner. The
  # new session starts with empty chat (Invariant #10). `template_name` is the
  # forked template's fresh unique name; `create_session` resolves it to the
  # version just persisted.
  defp create_session(%URI{} = workspace_uri, %URI{} = caller, caps, short_name, template_name) do
    case Ezagent.Workspace.create_session(
           workspace_uri,
           %{short_name: short_name, template_name: template_name},
           %{caller: caller, caps: caps}
         ) do
      {:ok, %{session_uri: %URI{} = uri}} -> {:ok, uri}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_create_session_result, other}}
    end
  end

  # --- caps + naming -----------------------------------------------------

  defp issue_fork_cap(%URI{} = source_template_uri, %URI{} = caller) do
    target = Ezagent.URI.with_action(source_template_uri, :template, :fork)

    Ezagent.Cap.issue_for_action(
      {:admin, Ezagent.Entity.User.admin_uri()},
      caller,
      target
    )
  end

  defp new_template_name(%URI{} = source_template_uri, opts) do
    case Keyword.get(opts, :new_template_name) do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        base = source_template_name(source_template_uri)
        "#{base}-copy-#{rand_suffix()}"
    end
  end

  defp short_name(opts) do
    case Keyword.get(opts, :short_name) do
      name when is_binary(name) and name != "" -> name
      _ -> "copy-#{rand_suffix()}"
    end
  end

  # The source SessionTemplate's NAME (the `<name>` before `@<hash>` in the
  # `template://session/<ws>/<name>@<hash>` URI).
  defp source_template_name(%URI{} = uri) do
    uri
    |> Ezagent.URI.name!()
    |> String.split("@", parts: 2)
    |> List.first()
  end

  defp rand_suffix, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end

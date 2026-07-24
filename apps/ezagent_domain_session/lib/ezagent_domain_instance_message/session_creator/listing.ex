defmodule EzagentDomainInstanceMessage.SessionCreator.Listing do
  @moduledoc false

  alias Ezagent.Entity.Session
  alias Ezagent.Identity

  @spec list_sessions :: [URI.t()]
  def list_sessions do
    Ezagent.Kind.list_instances()
    |> Enum.flat_map(fn {uri_str, _meta} ->
      case Ezagent.URI.parse(uri_str) do
        {:ok, %URI{} = uri} -> if Ezagent.URI.scheme?(uri, :session), do: [uri], else: []
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(&URI.to_string/1)
  end

  @spec list_sessions(URI.t()) :: [URI.t()]
  def list_sessions(%URI{scheme: "workspace"} = workspace_uri) do
    workspace_name = Ezagent.URI.name!(workspace_uri)

    list_sessions()
    |> Enum.filter(&session_in_workspace?(&1, workspace_name))
  end

  @doc """
  Workspace-scoped session listing filtered by membership.

  Returns only sessions in `workspace_uri` where `caller_uri` is a member.
  Admin callers (checked via `Ezagent.Identity.admin?/1`) bypass the
  membership filter and see all sessions in the workspace — this supports
  operator management surfaces without leaking cross-workspace data (the
  workspace scope is still enforced).

  A non-URI or `nil` caller is fail-closed (empty list) — anonymous or
  unauthenticated callers cannot be members of any session.

  ## Cold-boot durable listing (2026-07-08)

  The base enumeration is live ∪ durable (`persisted_session_entries/1` —
  the same union `list_persisted_sessions/1` exposes), NOT the live
  registry alone. Sessions are not auto-respawned on boot, so a live-only
  base showed an EMPTY `/sessions` after a container restart even though
  `kind_snapshots` held every session durably.

  Membership is evaluated per liveness, all read-only (a listing never
  force-spawns a cold Kind):

    * LIVE session — `Session.session_member_uris/1`, the exact
      pre-existing live read (behavior unchanged).
    * COLD session — `:members` decoded from the durable snapshot row the
      base enumeration ALREADY fetched (`KindSnapshot.decode_state/1` +
      `Session.member_uris_from_snapshot_state/1`); one decode per cold
      session, no extra queries. A row that fails to decode is fail-closed
      (member-less → excluded for non-admins).

  Tenant isolation (#1217 / W0) is preserved by construction: the durable
  rows come from the workspace-scoped `KindSnapshot.list_in_workspace/1`
  query AND still pass the same URI workspace-segment filter the live path
  uses, and a caller is only ever matched against the session's OWN member
  set — a non-member (same-workspace or cross-workspace) stays excluded
  exactly as before.
  """
  @spec list_sessions(URI.t(), URI.t() | nil) :: [URI.t()]
  def list_sessions(%URI{scheme: "workspace"} = workspace_uri, %URI{} = caller_uri) do
    entries = persisted_session_entries(workspace_uri)

    if Identity.admin?(caller_uri) do
      Enum.map(entries, fn {session_uri, _liveness} -> session_uri end)
    else
      caller_str = URI.to_string(caller_uri)

      entries
      |> Enum.filter(fn {session_uri, liveness} ->
        session_uri
        |> member_uris(liveness)
        |> Enum.any?(&(URI.to_string(&1) == caller_str))
      end)
      |> Enum.map(fn {session_uri, _liveness} -> session_uri end)
    end
  end

  def list_sessions(%URI{}, _caller_uri), do: []

  @doc """
  Live PLUS durably-persisted sessions in the workspace — the listing the world
  operator console shows, so a session survives a cold server restart (the plain
  `list_sessions/1` is live-registry only, for internal live-membership queries).
  A listed-but-cold session revives on open (`ConversationActions.do_self_join`
  calls `LocalRuntime.ensure_live/1`).
  """
  @spec list_persisted_sessions(URI.t()) :: [URI.t()]
  def list_persisted_sessions(%URI{scheme: "workspace"} = workspace_uri) do
    workspace_uri
    |> persisted_session_entries()
    |> Enum.map(fn {session_uri, _liveness} -> session_uri end)
  end

  def list_persisted_sessions(_), do: []

  # The live ∪ durable base enumeration `list_sessions/2` and
  # `list_persisted_sessions/1` share. Returns `{session_uri, {:live, row_or_nil}}`
  # or `{session_uri, {:cold, snapshot_row}}` sorted by URI string — the durable
  # row travels with BOTH entry kinds: cold entries decode membership from it
  # with no further queries (no N+1), and live-tagged entries keep it so a Kind
  # that dies between this scan and the membership read still resolves durably
  # (codex #1257 LOW — live/cold race) instead of vanishing for its member.
  # Read-only: never spawns/rehydrates a Kind.
  @spec persisted_session_entries(URI.t()) ::
          [{URI.t(), {:live, struct() | nil} | {:cold, struct()}}]
  defp persisted_session_entries(%URI{scheme: "workspace"} = workspace_uri) do
    workspace_name = Ezagent.URI.name!(workspace_uri)

    live =
      list_sessions()
      |> Enum.filter(&session_in_workspace?(&1, workspace_name))

    # Dedup keys are CANONICAL URI structs (`Ezagent.URI.canonical!/1`), not
    # `URI.to_string` — string-keyed URI collections are the `uri_string_key`
    # scan class (URI = opaque id; a URI reorder would silently split the
    # live/cold join). Both sides normalize through the same fn, so struct
    # equality is safe as a key.
    live_set = MapSet.new(live, &Ezagent.URI.canonical!/1)

    rows = persisted_session_rows(workspace_uri, workspace_name)
    rows_by_uri = Map.new(rows, fn {uri, row} -> {Ezagent.URI.canonical!(uri), row} end)

    cold =
      Enum.reject(rows, fn {uri, _row} ->
        MapSet.member?(live_set, Ezagent.URI.canonical!(uri))
      end)

    live_entries =
      Enum.map(live, fn uri ->
        {uri, {:live, Map.get(rows_by_uri, Ezagent.URI.canonical!(uri))}}
      end)

    cold_entries = Enum.map(cold, fn {uri, row} -> {uri, {:cold, row}} end)

    (live_entries ++ cold_entries)
    |> Enum.sort_by(fn {uri, _liveness} -> URI.to_string(uri) end)
  end

  # Durable session snapshot rows (kind_type "session") in the workspace —
  # the substrate does NOT auto-respawn every session on boot (the
  # cold-restart respawn gap), so the live registry alone under-reports
  # after a restart. Tenant scope is enforced twice on purpose: the SQL
  # query is workspace-scoped (`list_in_workspace/1`, SPEC v3 §7.2) AND
  # every row's URI must carry the workspace as its authority segment
  # (`session_in_workspace?/2` — the same filter the live path uses).
  # Fail-closed on any storage error.
  defp persisted_session_rows(workspace_uri, workspace_name) do
    Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)
    |> Enum.flat_map(fn snap ->
      with "session" <- Map.get(snap, :kind_type),
           uri_str when is_binary(uri_str) <- Map.get(snap, :uri),
           {:ok, %URI{} = uri} <- Ezagent.URI.parse(uri_str),
           true <- Ezagent.URI.scheme?(uri, :session),
           true <- session_in_workspace?(uri, workspace_name) do
        [{uri, snap}]
      else
        _ -> []
      end
    end)
  rescue
    _ -> []
  end

  # Membership per liveness — live sessions keep the exact pre-existing
  # live read; cold sessions read the durable `:members` from the
  # already-fetched snapshot row. Fail-closed: an undecodable row has no
  # members.
  #
  # Live/cold race (codex #1257 LOW): a Kind tagged live at scan time can
  # die before this membership read; `session_member_uris/1` then returns
  # `[]` (its not-live contract). Only in that case — empty AND the Kind
  # verifiably gone from the registry — fall back to the durable row the
  # scan already carried. A genuinely-live session's empty roster is NOT
  # overridden (the registry lookup still succeeds), so live semantics are
  # unchanged.
  defp member_uris(session_uri, {:live, row}) do
    case Session.session_member_uris(session_uri) do
      [] ->
        if Ezagent.Kind.alive?(session_uri) do
          []
        else
          cold_member_uris(row)
        end

      members ->
        members
    end
  end

  defp member_uris(_session_uri, {:cold, row}), do: cold_member_uris(row)

  defp cold_member_uris(nil), do: []

  defp cold_member_uris(row) do
    case Ezagent.Ecto.KindSnapshot.decode_state(row) do
      {:ok, state} -> Session.member_uris_from_snapshot_state(state)
      _ -> []
    end
  end

  @doc false
  @spec agent_live_sessions(URI.t()) :: {:ok, [URI.t()]} | {:error, term()}
  def agent_live_sessions(%URI{} = agent_uri) do
    case Ezagent.URI.workspace_of(agent_uri) do
      %URI{} = workspace_uri ->
        target = URI.to_string(agent_uri)

        sessions =
          workspace_uri
          |> list_sessions()
          |> Enum.filter(fn session_uri ->
            session_uri
            |> Session.session_member_uris()
            |> Enum.any?(&(URI.to_string(&1) == target))
          end)

        {:ok, sessions}

      :any ->
        {:error, :invalid_agent_uri}
    end
  end

  def agent_live_sessions(_), do: {:error, :invalid_agent_uri}

  @doc false
  @spec agent_in_live_session?(URI.t()) :: {:ok, boolean()} | {:error, term()}
  def agent_in_live_session?(%URI{} = agent_uri) do
    case agent_live_sessions(agent_uri) do
      {:ok, sessions} -> {:ok, sessions != []}
      {:error, _reason} = error -> error
    end
  end

  defp session_in_workspace?(%URI{} = session_uri, workspace_name) do
    case Ezagent.URI.workspace_name(session_uri) do
      {:ok, ^workspace_name} -> true
      _ -> false
    end
  end

  defp session_in_workspace?(_, _), do: false
end

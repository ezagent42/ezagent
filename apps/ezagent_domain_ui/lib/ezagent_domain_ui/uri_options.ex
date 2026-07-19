defmodule Ezagent.UI.UriOptions do
  @moduledoc """
  V1 UI PR-1 (SPEC §1.3) — option source + URI validator for the
  `EzagentDomainUi.Primitives.uri_picker/1` component.

  `Ezagent.KindRegistry.list_all/0` is a GLOBAL `URI → pid` index — it
  has no notion of who is asking. Returning every live URI to every
  user leaks cross-workspace entity names; pre-rework this module
  enumerated it directly under a URI-segment authority rule (system
  member OR own workspace), which still leaked a workspace's WHOLE
  roster to any caller who could name it — including private
  sessions/agents the caller had no relationship to (F1, read-plane
  PR-4 rework). This module is now ONLY the enrichment layer: the
  enumeration itself routes through the caller-authorizing
  chokepoints —

    * sessions → `Ezagent.Workspace.WorkspaceReads.sessions/2`
      (owner/member OR public, per row),
    * agents   → `Ezagent.Workspace.WorkspaceReads.agents/2`
      (caller owns/manages, or the shared roster for workspace
      MEMBERS),
    * users    → `Ezagent.Workspace.UserReads.users/2`
      (workspace member/operator roster),

  which authorize the caller FIRST and fail closed to `[]`. The option
  maps (`%{uri, label, kind, flavor}`) are built from the chokepoint
  results exactly as before.

  ## The shared validator

  `valid_for?/4` is used by BOTH the option-build path (each public
  `entities/2` etc. filters its candidates through the same
  scheme/workspace logic) AND the submit-revalidate path in every
  converted picker form (SPEC §1.6). The picker's hidden inputs are
  user-controlled DOM — a stale or hand-tampered URI must be rejected
  server-side. Factoring the check here means the two sides cannot
  drift. Its authority rule is unchanged: a system member may validate
  any workspace; any other caller only its OWN workspace (the
  `Ezagent.Capability.workspace_of/1` derivation dispatch step 5.6
  uses).
  """

  alias Ezagent.{Capability, EntityPresenter}
  alias Ezagent.Workspace.{UserReads, WorkspaceReads}

  @type option :: %{
          uri: String.t(),
          label: String.t(),
          kind: atom(),
          flavor: String.t() | nil
        }

  @doc """
  Entity URIs (users + agents) the caller may see in `workspace_uri`.

  Returns `[]` when the caller is not authorized for `workspace_uri`
  (see the module doc authority rule).
  """
  @spec entities(caller_uri :: String.t() | URI.t(), workspace_uri :: String.t() | URI.t()) ::
          [option()]
  def entities(caller_uri, workspace_uri),
    do: build_options(caller_uri, workspace_uri, [:entity])

  @doc """
  Session URIs the caller may see in `workspace_uri`.

  Returns `[]` when the caller is not authorized for `workspace_uri`.
  """
  @spec sessions(caller_uri :: String.t() | URI.t(), workspace_uri :: String.t() | URI.t()) ::
          [option()]
  def sessions(caller_uri, workspace_uri),
    do: build_options(caller_uri, workspace_uri, [:session])

  @doc """
  Entities + sessions together — for receiver fields that accept both.

  Returns `[]` when the caller is not authorized for `workspace_uri`.
  """
  @spec entities_and_sessions(
          caller_uri :: String.t() | URI.t(),
          workspace_uri :: String.t() | URI.t()
        ) :: [option()]
  def entities_and_sessions(caller_uri, workspace_uri),
    do: build_options(caller_uri, workspace_uri, [:entity, :session])

  @doc """
  Is `uri` a valid pick for the caller, in `workspace_uri`, for
  `kinds`?

  **The shared validator** (SPEC §1.6) — used by BOTH the option-build
  path (`entities/2` etc. filter their candidates through the same
  scheme + workspace logic) AND the submit-revalidate path in every
  converted picker form. The picker's hidden inputs are user-controlled
  DOM; a stale or hand-tampered URI must be rejected server-side.
  Factoring the tenant-boundary check here means the two paths cannot
  drift.

  A submitted picker URI is valid when ALL of:

  1. It is well-formed per `Ezagent.URI.new!/1` (registered scheme,
     correct 3-segment shape).
  2. Its scheme is one of `kinds` (`:entity` / `:session`).
  3. The caller is authorized to see `workspace_uri` (system member,
     or `workspace_uri` is the caller's own — same authority rule as
     `entities/2`).
  4. The URI's own workspace segment equals `workspace_uri` — a URI
     for a different workspace is rejected even when the caller holds
     cross-workspace authority, because a picker field is scoped to
     one workspace at a time.

  Liveness is NOT checked here. SPEC §1.6 (c) makes "the target
  actually exists" conditional ("where the action needs it"), and
  SPEC §1.4 explicitly supports referencing a URI not yet live (a
  routing rule targeting an agent to be created later; a workspace
  member declaration). The picker's *options* are live entities; the
  free-text fallback is the not-yet-live escape hatch — revalidation
  must not negate it. Call sites that genuinely require a live target
  do their own `KindRegistry.lookup/1` (the dispatch path already
  fails closed on a dead target).

  Returns `false` (never raises) on any malformed input — a bad
  submit is a flash error at the call site, not a crash.
  """
  @spec valid_for?(
          caller_uri :: String.t() | URI.t(),
          workspace_uri :: String.t() | URI.t(),
          uri :: String.t() | URI.t(),
          kinds :: [atom()]
        ) :: boolean()
  def valid_for?(caller_uri, workspace_uri, uri, kinds)
      when is_list(kinds) do
    with {:ok, target} <- safe_parse(uri),
         true <- target.scheme in scheme_strings(kinds),
         {:ok, ws} <- safe_parse(workspace_uri),
         true <- authorized?(caller_uri, ws),
         {:ok, target_ws} <- workspace_of_uri(target),
         true <- URI.to_string(target_ws) == URI.to_string(ws) do
      true
    else
      _ -> false
    end
  end

  def valid_for?(_caller_uri, _workspace_uri, _uri, _kinds), do: false

  # --- internals -------------------------------------------------------------

  # Read-plane PR-4 rework: the enumeration routes through the
  # caller-authorizing chokepoints (they authorize FIRST and fail closed
  # to `[]`), then each surviving URI is enriched into an option map.
  # There is no local authority gate here on purpose — duplicating the
  # chokepoint's authorization would drift from it.
  defp build_options(caller_uri, workspace_uri, kinds) do
    with {:ok, ws} <- safe_parse(workspace_uri),
         {:ok, caller} <- safe_parse(caller_uri) do
      wanted = scheme_strings(kinds)

      (session_uris(caller, ws, wanted) ++ entity_uris(caller, ws, wanted))
      |> Enum.uniq_by(&URI.to_string/1)
      |> Enum.flat_map(&enrich(&1, wanted))
      |> Enum.sort_by(& &1.uri)
    else
      _ -> []
    end
  end

  # Session options — the caller-visible session list per
  # `WorkspaceReads.sessions/2` (owner/member OR public, per row).
  defp session_uris(%URI{} = caller, %URI{} = ws, wanted) do
    if "session" in wanted do
      WorkspaceReads.sessions(caller, ws)
    else
      []
    end
  end

  # Entity options — agents via `WorkspaceReads.agents/2` (owns/manages,
  # or the shared roster for workspace members), users via
  # `UserReads.users/2` (member/operator roster).
  defp entity_uris(%URI{} = caller, %URI{} = ws, wanted) do
    if "entity" in wanted do
      WorkspaceReads.agents(caller, ws) ++
        Enum.map(UserReads.users(caller, ws), & &1.uri)
    else
      []
    end
  end

  # Parse, scheme-filter, then build the option map. Any URI that fails
  # to parse (a chokepoint holding a non-canonical row, which
  # `parse!/1` rejects) is silently dropped from options — it
  # could never be a valid pick anyway.
  defp enrich(%URI{} = uri, wanted_schemes) do
    uri_str = URI.to_string(uri)

    if uri.scheme in wanted_schemes do
      [
        %{
          uri: uri_str,
          label: EntityPresenter.display(uri_str),
          kind: String.to_existing_atom(uri.scheme),
          flavor: flavor_of(uri)
        }
      ]
    else
      []
    end
  end

  # The caller is authorized for `workspace_uri` when it is a system
  # member (any workspace) OR `workspace_uri` is the caller's own.
  defp authorized?(caller_uri, %URI{} = workspace_uri) do
    case caller_workspace(caller_uri) do
      {:ok, caller_ws} ->
        system_member?(caller_ws) or
          URI.to_string(caller_ws) == URI.to_string(workspace_uri)

      :error ->
        false
    end
  end

  defp system_member?(%URI{} = workspace_uri),
    do: Ezagent.URI.stable_key(workspace_uri) == system_workspace_key()

  defp system_workspace_key, do: :system |> Ezagent.URI.workspace() |> Ezagent.URI.stable_key()

  # Derive the caller's workspace via the SAME mechanism dispatch step
  # 5.6 / `Ezagent.Capability.cross_workspace?/2` use:
  # `Ezagent.Capability.workspace_of/1`. For an `entity://` URI this
  # delegates to `Ezagent.URI.entity_workspace_uri/1`.
  defp caller_workspace(caller_uri) do
    with {:ok, uri} <- safe_parse(caller_uri),
         %URI{} = ws <- safe_workspace_of(uri) do
      {:ok, ws}
    else
      _ -> :error
    end
  end

  defp safe_workspace_of(%URI{} = uri) do
    Capability.workspace_of(uri)
  rescue
    _ -> :error
  end

  defp workspace_of_uri(%URI{} = uri) do
    case safe_workspace_of(uri) do
      %URI{} = ws -> {:ok, ws}
      _ -> :error
    end
  end

  defp safe_parse(%URI{} = uri), do: {:ok, uri}

  defp safe_parse(str) when is_binary(str) do
    {:ok, Ezagent.URI.new!(str)}
  rescue
    _ -> :error
  end

  defp safe_parse(_), do: :error

  defp scheme_strings(kinds), do: Enum.map(kinds, &Atom.to_string/1)

  # Agent flavor is stored metadata. URI names are opaque to UI code.
  defp flavor_of(%URI{scheme: "entity"} = uri) do
    if Ezagent.URI.type?(uri, :agent) do
      case Ezagent.UriQuery.resolve(:flavor, uri) do
        {:ok, flavor} when is_binary(flavor) and flavor != "" -> flavor
        :none -> nil
        {:ok, _other} -> nil
        {:error, _reason} -> nil
      end
    else
      nil
    end
  end

  defp flavor_of(%URI{}), do: nil
end

defmodule Ezagent.WorkspaceRegistry do
  @moduledoc """
  Session → Workspace back-edge.

  ## Phase 9 PR-7 — demoted to consistency cache (SPEC v3 §3.6)

  After URI scheme unification, every session URI carries its
  workspace as the second path segment
  (`session://<template>/<workspace>/<name>`). Workspace derivation
  is now structural / O(1) via `Ezagent.Capability.workspace_of/1` —
  the registry is no longer the authoritative source for sessions.

  The registry is retained as a consistency cache for code paths
  that hold a session URI and want to look up its workspace without
  re-parsing. The
  `all_per_tenant_uris_have_workspace_test` invariant pins that
  every binding equals the workspace segment of its bound URI.

  Phase 7 PR 31 (IMPL-7-1) — historical context: production routing
  dispatch via `Ezagent.Behavior.Chat.invoke(:send, ...)` needed to
  know which workspace a session belongs to so it could pass
  `workspace_uri:` to `Ezagent.Routing.Resolver.resolve/4`. PR-7
  replaces that lookup with structural extraction; the routing
  Resolver still accepts the bound workspace as an `opts` field.

  ## Why an ETS Registry, not a Chat slice field

  - `Ezagent.SpawnRegistry.spawn/1` is URI-only by Decision #65 (no
    Kind-specific args). Threading workspace_uri through spawn would
    break that invariant.
  - Chat Behavior's slice stays orthogonal to workspace concept;
    Workspace is a higher-level coupling concern.
  - No migration needed: unbound sessions (existing snapshots) lookup
    returns `nil` → workspace_uri opt defaults to nil → Resolver
    behaves exactly as today (global scope, no filtering).
  - Matches the existing 4-Registry pattern (Kind / Behavior /
    Routing / Spawn / Template); this becomes the fifth.

  ## Plugin author contract

  A Template Class that spawns a Session for a Workspace MUST call
  `bind(session_uri, workspace_uri)` after `SpawnRegistry.spawn/1`.
  `Ezagent.Workspace.Loader` does this for the canonical session-template
  classes; plugin authors implementing custom session-spawning
  Template Classes follow the same pattern.

  ## ETS layout

  `:ezagent_workspace_registry` set table owned by `EzagentCore.EtsOwner`.
  Keys are session URI strings, values are workspace URI strings.

  Lookups are O(1) and lock-free (ETS read_concurrency).
  """

  @table :ezagent_workspace_registry

  def table, do: @table

  @doc """
  Legacy `workspace://default` fallback constant.

  ## Why "legacy"

  Phase 8c PR-E (Allen 2026-05-20) introduced this as the canonical
  default workspace URI. SPEC v2 PR-C (#295) deleted the boot-seeded
  `default` workspace row (only `workspace://system` is seeded now);
  SPEC v2 PR-F (this PR) leaves the function in place because:

  - **Audit / snapshot fallback** (`Ezagent.Persistence.default_workspace_uri/0`,
    `Ezagent.Audit.derive_workspace/2`) still needs a non-nullable
    `workspace_uri` string for rows whose caller/target genuinely have
    no workspace context (e.g. system bootstrap events). The string is
    written as-is — there is no FK to `workspaces.uri`.
  - **Test fixtures** that hardcode `session://default/default/main`
    (~10 suites) read this through the chat facade fallback. PR-F's
    1st-pass scope is production lib code only; test fixture cleanup
    is the 2nd-pass.

  Production code that creates sessions or per-tenant entities MUST
  pass workspace explicitly (the wizard / onboarding LV / mix task
  callers already do). Do NOT introduce new callers of this fallback.

  Returns `{:ok, URI.t()}` always.
  """
  @spec default_workspace_uri() :: {:ok, URI.t()}
  def default_workspace_uri do
    {:ok, URI.new!("workspace://default")}
  end

  @doc """
  Record that `session_uri` belongs to `workspace_uri`. Idempotent —
  re-binding the same session to the same workspace is a no-op;
  re-binding to a different workspace silently overwrites (the most
  recent Loader run wins, which matches the existing Workspace.Loader
  re-hydration pattern).

  Returns `:ok` always.
  """
  @spec bind(URI.t() | String.t(), URI.t() | String.t()) :: :ok
  def bind(session_uri, workspace_uri) do
    s = uri_to_str(session_uri)
    w = uri_to_str(workspace_uri)
    :ets.insert(@table, {s, w})
    :ok
  end

  @doc """
  Remove the binding for `session_uri`. Returns `:ok` whether or not
  a binding existed.
  """
  @spec unbind(URI.t() | String.t()) :: :ok
  def unbind(session_uri) do
    :ets.delete(@table, uri_to_str(session_uri))
    :ok
  end

  @doc """
  Look up the workspace URI for `session_uri`. Returns `{:ok, %URI{}}`
  if bound, `:error` otherwise.

  Unbound is **not** an error — callers (Chat.invoke(:send)) treat
  `:error` as "no workspace scope" and let Resolver behave globally,
  preserving pre-PR-31 behavior.
  """
  @spec lookup(URI.t() | String.t()) :: {:ok, URI.t()} | :error
  def lookup(session_uri) do
    s = uri_to_str(session_uri)

    case :ets.lookup(@table, s) do
      [{^s, w}] -> {:ok, URI.parse(w)}
      [] -> :error
    end
  end

  @doc "List all bindings as `[{session_uri_str, workspace_uri_str}]`."
  @spec list_all() :: [{String.t(), String.t()}]
  def list_all do
    :ets.tab2list(@table)
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end

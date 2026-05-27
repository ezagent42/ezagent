defmodule Ezagent.Persistence do
  @moduledoc """
  Per-workspace data isolation helpers (Phase 9 PR-6 / SPEC v3 §7).

  Centralizes:

  1. **Read-time scoping** — `scope_by_workspace/2` adds the
     `where workspace_uri = ?` clause to any Ecto queryable. Use in
     every read path against per-tenant tables (`messages`,
     `invocations`, `kind_snapshots`, `users`, `entity_tokens`,
     `entity_profiles`).

  2. **Write-time derivation** — `workspace_uri_for/1` returns the
     `workspace_uri` string to set on a row given the row's owning URI.
     Wraps `Ezagent.Capability.workspace_of/1` (the existing dispatch-
     time helper) and stringifies the result so callers can drop the
     string straight into a changeset / `Ecto.Changeset.change/2`.

  ## Why a single chokepoint

  Per SPEC §7 + memory `feedback_let_it_crash_no_workarounds`: if a
  read path forgets to scope, data leaks across tenants — silently.
  Routing every read through this module gives us one grep target
  (`Ezagent.Persistence.scope_by_workspace`) that audit + invariant
  tests can pin. Same for writes: every changeset that needs
  `workspace_uri` reads it from `workspace_uri_for/1` — divergent
  derivation between callers is the kind of drift PR-6 is designed
  to prevent.

  ## Exemption pattern

  Admin / system-scope reads (e.g. listing every workspace, listing
  every session for an operator dashboard) intentionally bypass
  `scope_by_workspace/2`. The function moduledoc of every such read
  path MUST document the exemption + cite this paragraph; the
  invariant test exemption list (`per_tenant_tables_have_workspace_column_test`)
  is the durable record.
  """

  import Ecto.Query

  @doc """
  Scope an Ecto queryable by `workspace_uri`. Adds
  `where: q.workspace_uri == ^workspace_uri` to the query.

  Accepts a `%URI{}` or string; normalizes to string before
  comparing (column stores the canonical `workspace://<name>` form).

  ## Examples

      iex> import Ecto.Query
      iex> q = Ezagent.Persistence.scope_by_workspace(Ezagent.Message, Ezagent.URI.parse!("workspace://team-alpha"))
      iex> %Ecto.Query{} = q
      iex> Macro.to_string(q.wheres |> hd() |> Map.get(:expr)) =~ "workspace_uri"
      true
  """
  @spec scope_by_workspace(Ecto.Queryable.t(), URI.t() | String.t()) :: Ecto.Query.t()
  def scope_by_workspace(queryable, %URI{} = workspace_uri),
    do: scope_by_workspace(queryable, URI.to_string(workspace_uri))

  def scope_by_workspace(queryable, workspace_uri) when is_binary(workspace_uri) do
    from q in queryable, where: q.workspace_uri == ^workspace_uri
  end

  @doc """
  Derive the canonical `workspace_uri` string to set on a row, given
  the row's owning URI.

  Delegates to `Ezagent.Capability.workspace_of/1` (the existing
  dispatch-time helper — SPEC v3 §4.2). Three return shapes:

  - `entity://<type>/<workspace>/<name>` → `"workspace://<workspace>"`
  - `session://<template>/<name>` → workspace via WorkspaceRegistry
    (raises if unbound — invariant 4)
  - `workspace://<name>` → the URI itself, stringified

  For cross-workspace / cross-cutting URIs (`system://`, `template://`,
  `resource://`, unknown schemes), `Capability.workspace_of/1` returns
  `:any` — this module REJECTS that with `{:error, :no_workspace}` so
  the caller is forced to supply an explicit fallback. The
  column is `null: false`, so silent `:any` would crash the insert
  with a less helpful error.

  Per SPEC #324 rev 3 (Allen 2026-05-25): there is NO global default
  workspace function. Cross-cutting writers (audit / snapshot of
  `system://` URIs) inline the `"workspace://system"` literal at the
  write site — never via a shared helper, because a shared helper hides
  "no workspace passed" bugs as silent fallbacks. Every other writer
  derives workspace structurally from the entity URI or raises.
  """
  @spec workspace_uri_for(URI.t() | String.t()) ::
          {:ok, String.t()} | {:error, :no_workspace}
  def workspace_uri_for(%URI{} = uri) do
    case Ezagent.Capability.workspace_of(uri) do
      %URI{} = ws -> {:ok, URI.to_string(ws)}
      :any -> {:error, :no_workspace}
    end
  end

  def workspace_uri_for(uri) when is_binary(uri),
    do: workspace_uri_for(Ezagent.URI.parse!(uri))

  @doc """
  Like `workspace_uri_for/1` but raises `ArgumentError` on
  `:no_workspace`. Use at insert sites where caller knows the URI is
  workspace-bound (entity / session / workspace) and `:any` would be
  a structural bug.
  """
  @spec workspace_uri_for!(URI.t() | String.t()) :: String.t()
  def workspace_uri_for!(uri) do
    case workspace_uri_for(uri) do
      {:ok, ws} ->
        ws

      {:error, :no_workspace} ->
        raise ArgumentError,
              "no workspace can be derived from #{inspect(uri)} — " <>
                "cross-cutting URI schemes (system://, template://, resource://) " <>
                "require an explicit fallback workspace at the insert site."
    end
  end

  # SPEC #324 rev 3 (Allen 2026-05-25): `default_workspace_uri/0` was
  # DELETED. A global fallback hides "no workspace passed" bugs as
  # silent silent-defaults — exactly what `feedback_let_it_crash_no_workarounds`
  # forbids. Cross-cutting writers (audit / snapshot of `system://` URIs)
  # MUST inline the `"workspace://system"` literal at the write site
  # with a comment explaining why (a system:// URI naturally lands in
  # the admin workspace, which exists at deploy seed time). Every other
  # writer derives workspace structurally via
  # `Ezagent.URI.entity_workspace_uri/1` or `workspace_uri_for!/1`, or
  # raises ArgumentError.
end

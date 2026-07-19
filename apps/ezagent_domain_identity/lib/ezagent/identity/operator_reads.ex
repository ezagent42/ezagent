defmodule Ezagent.Identity.OperatorReads do
  @moduledoc """
  The single operator-gated read chokepoint for GLOBAL registry list-all
  reads — the `Ezagent.KindRegistry.list_all/0` enumeration of every Kind
  instance (sessions, agents, entities, …) across the WHOLE system.

  ## Why this exists

  Global list-all reads are an OPERATOR query-scope: they cross every
  workspace and every tenant boundary at once, so workspace membership is
  meaningless as an authorization signal — the gate is the OPERATOR/admin
  cap, not membership. Before this module, admin surfaces called
  `Ezagent.KindRegistry.list_all/0` directly with zero authorization.
  `OperatorReads` is the chokepoint (same shape as
  `Ezagent.Socialware.SessionReads`, but gating an operator instead of a
  session member): **every global registry read routes through here, is
  authorized FIRST, and only then touches the registry.**

  ## Contract (binding)

  `registry_all/1` takes `caller` FIRST and authorizes BEFORE any read. A
  non-operator / nil / malformed caller gets `{:error, :unauthorized}`
  (fail-closed) — never a degraded or partial list. The error is
  PROPAGATED to the caller: the presenter must surface an explicit
  unauthorized state, never coerce it to an empty table (F5, read-plane
  PR-4 rework).

  ## Authorization predicate

  Delegates to `Ezagent.Identity.AdminAuthority.admin?/2` — the SAME
  4-predicate operator authority the workspace-listing plane
  (`Ezagent.Workspace.Listing.list_workspaces_for/2`) uses — so a
  PROMOTED operator (cross-workspace admin cap holder, or a declared
  `workspace://system` member) is accepted, not just the bootstrap admin
  URI (F5, read-plane PR-4 rework: the old `Identity.admin?/1`
  exact-URI-equality gate locked promoted operators out). The caller's
  caps are loaded LIVE (`Ezagent.EntityCaps.load/1`) so a fresh promotion
  is seen immediately and a revoked one stops authorizing at once.
  """

  alias Ezagent.Identity.AdminAuthority

  @doc """
  Authorized GLOBAL registry list-all for `caller`.

  Authorizes `caller` as an OPERATOR/admin BEFORE reading. On success
  returns `{:ok, [{uri_string, pid}]}` (the raw
  `Ezagent.KindRegistry.list_all/0` shape); a non-operator / nil /
  malformed caller gets `{:error, :unauthorized}`.
  """
  @spec registry_all(URI.t() | String.t() | term()) ::
          {:ok, [{String.t(), pid()}]} | {:error, :unauthorized}
  def registry_all(caller) do
    with :ok <- authorize(caller) do
      {:ok, Ezagent.KindRegistry.list_all()}
    end
  end

  # ----- authorization (operator cap, fail-closed) ---------------------------

  # F5 (read-plane PR-4 rework): `AdminAuthority.admin?/2` — the same
  # operator-listing predicate the workspace plane uses — over the
  # caller's LIVE-loaded caps. A malformed caller or a caps-load failure
  # fails closed to `{:error, :unauthorized}`.
  defp authorize(%URI{} = caller) do
    caps = Ezagent.EntityCaps.load(caller)

    if AdminAuthority.admin?(caller, caps) do
      :ok
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  defp authorize(caller) when is_binary(caller) do
    case Ezagent.URI.parse(caller) do
      {:ok, %URI{} = uri} -> authorize(uri)
      _ -> {:error, :unauthorized}
    end
  end

  defp authorize(_caller), do: {:error, :unauthorized}
end

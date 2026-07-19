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
  (fail-closed) — never a degraded or partial list.

  ## Authorization predicate

  Delegates to `Ezagent.Identity.admin?/1` — the SAME operator predicate
  the admin surfaces (`Ezagent.World.AdminData.settings_state/1`) already
  gate on — so the read-plane and the UI agree on who is an operator.
  """

  alias Ezagent.Identity

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

  defp authorize(caller) do
    if Identity.admin?(caller), do: :ok, else: {:error, :unauthorized}
  end
end

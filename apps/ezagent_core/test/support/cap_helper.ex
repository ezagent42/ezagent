defmodule Ezagent.Test.CapHelper do
  @moduledoc """
  Phase 9 PR-3 (SPEC v3 §4) — test helper for constructing
  `Ezagent.Capability` structs without re-specifying the boilerplate
  fields (`workspace_uri`, `granted_by`, `granted_at`).

  The struct gained `workspace_uri` as a required field
  (`@enforce_keys`); rather than rewrite every test cap site to
  hand-thread the new field, tests build caps via `cap/1`:

      import Ezagent.Test.CapHelper

      cap = cap(kind: :session, behavior: :any, instance: :any)
      # → %Capability{kind: :session, behavior: :any, instance: :any,
      #              workspace_uri: %URI{scheme: "workspace", host: "system"},
      #              granted_by: %URI{scheme: "entity", ...},
      #              granted_at: ~U[...]}

  Tests that need a specific workspace pass `workspace_uri:` explicitly:

      cap(kind: :session, behavior: :any, instance: :any,
          workspace_uri: URI.new!("workspace://team-alpha"))

  Compiled only in `:test` per `apps/ezagent_core/mix.exs`
  `elixirc_paths(:test)`. Available to every umbrella app via
  `import` once the parent test depends on `ezagent_core`.

  ## Why a helper instead of updating each test cap inline

  Per the spec: ~30+ cap construction sites between lib + tests. Lib
  sites get the explicit workspace dimension because they live in
  production code paths. Test sites get a default so the contract
  pin stays focused on the test's actual concern (kind / behavior /
  instance matching), not workspace plumbing.
  """

  alias Ezagent.Capability

  # SPEC #324 — renamed from `@default_workspace` (legacy
  # `workspace://default` literal) because the SPEC banned the silent
  # `default` workspace name. Tests that want an admin-scope cap use
  # `@system_workspace`; tests that need a tenant-scope cap pass
  # `workspace_uri:` explicitly (or use `@tenant_workspace` for a
  # stable tenant name).
  @default_granted_at ~U[2026-05-21 00:00:00Z]

  @doc """
  Build a `%Ezagent.Capability{}` with sensible test defaults.

  Required key absent → defaults applied:
  - `workspace_uri` → `workspace://system` (admin/system context — see
    SPEC #324 for why tenants must be explicit)
  - `granted_by` → `entity://system/user/admin`
  - `granted_at` → `2026-05-21T00:00:00Z`

  Pass any subset of keys to override; remaining keys default to
  `:any` (for `kind` / `behavior` / `instance`).

  ## Examples

      cap(kind: :session, behavior: Ezagent.ActionSet.Session,
          instance: URI.new!("session://system/default/main"))

      cap(kind: :any, behavior: :any, instance: :any,
          workspace_uri: :any)  # cross-workspace cap (admin pattern)

      cap(kind: :session, behavior: :any, instance: :any,
          workspace_uri: tenant_workspace_uri())  # tenant context
  """
  @spec cap(keyword() | map()) :: Capability.t()
  def cap(opts) when is_list(opts) or is_map(opts) do
    # SPEC 2026-05-27 capability-action-axis — `:action` defaults to
    # `:any` (wildcard). Tests asserting concrete-action gating pass
    # `action:` explicitly.
    defaults = %{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: :any,
      workspace_uri: system_workspace_uri(),
      granted_by: default_granter_uri(),
      granted_at: @default_granted_at
    }

    merged = Map.merge(defaults, Enum.into(opts, %{}))
    struct!(Capability, merged)
  end

  @doc "Issue a test capability through the production signing chokepoint."
  @spec issue!(URI.t() | String.t(), Capability.t(), Ezagent.Cap.authorization() | nil) ::
          Capability.t()
  def issue!(receiver, %Capability{} = proposal, authorization \\ nil) do
    receiver = if is_binary(receiver), do: Ezagent.URI.new!(receiver), else: receiver
    authorization = authorization || {:genesis, proposal.granted_by}

    case Ezagent.Cap.issue(authorization, receiver, proposal) do
      {:ok, artifact} -> artifact
      {:error, reason} -> raise "test cap issuance failed: #{inspect(reason)}"
    end
  end

  @doc "Issue a collection of test capabilities through the production signing chokepoint."
  @spec issue_all!(URI.t() | String.t(), Enumerable.t()) :: [Capability.t()]
  def issue_all!(receiver, proposals) do
    Enum.map(proposals, &issue!(receiver, &1))
  end

  @doc """
  Build a `needed` map for `Ezagent.Capability.matches?/2` with test
  defaults — mirror of `cap/1` for the lookup side.

  Defaults:
  - `kind` → `:any` (so a kind-less needed accidentally matches
    nothing — explicit kind is the norm)
  - `workspace_uri` → `workspace://system`

  ## Examples

      needed(kind: :session, behavior: Ezagent.ActionSet.Session,
             instance: URI.new!("session://system/default/main"))
  """
  @spec needed(keyword() | map()) :: %{
          kind: atom(),
          behavior: module() | atom(),
          action: atom(),
          instance: URI.t(),
          workspace_uri: URI.t() | :any
        }
  def needed(opts) when is_list(opts) or is_map(opts) do
    # SPEC 2026-05-27 capability-action-axis — `:action` defaults to
    # `:any` so existing tests that don't care about action axis
    # continue to pass; tests asserting concrete-action behavior pass
    # `action:` explicitly.
    defaults = %{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: :any,
      workspace_uri: system_workspace_uri()
    }

    Map.merge(defaults, Enum.into(opts, %{}))
  end

  @doc "Default test workspace URI: `workspace://system` (admin/system)."
  @spec system_workspace_uri() :: URI.t()
  def system_workspace_uri, do: Ezagent.URI.workspace(:system)

  @doc "Stable tenant test workspace URI: `workspace://team-alpha`."
  @spec tenant_workspace_uri() :: URI.t()
  def tenant_workspace_uri, do: Ezagent.URI.workspace("team-alpha")

  defp default_granter_uri, do: Ezagent.URI.user(:system, :admin)
end

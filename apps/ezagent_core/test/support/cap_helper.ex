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

  @doc "Issue the capability required by an action-bearing target to `grantee`."
  @spec signed_action_cap!(URI.t(), URI.t()) :: Capability.t()
  def signed_action_cap!(%URI{} = target, %URI{} = grantee) do
    case Ezagent.Cap.issue_for_action({:admin, admin_uri()}, grantee, target) do
      {:ok, cap} -> cap
      {:error, reason} -> raise "test capability issuance failed: #{inspect(reason)}"
    end
  end

  @doc "Ask a live target Kind to sign an explicit test capability."
  @spec signed_cap!(URI.t(), URI.t(), Capability.t()) :: Capability.t()
  def signed_cap!(%URI{} = target, %URI{} = grantee, %Capability{} = cap) do
    requested = %{cap | instance: Ezagent.URI.instance(target)}

    case Ezagent.Cap.issue({:admin, admin_uri()}, grantee, requested) do
      {:ok, issued} -> issued
      {:error, reason} -> raise "test capability issuance failed: #{inspect(reason)}"
    end
  end

  @doc "Run a direct Runtime unit-test call inside a fresh target authority compartment."
  @spec with_test_authority(URI.t(), atom(), (Ezagent.Cap.Authority.t() -> result)) :: result
        when result: term()
  def with_test_authority(%URI{} = target, kind_type, fun)
      when is_atom(kind_type) and is_function(fun, 1) do
    case Ezagent.Cap.Authority.open(Ezagent.URI.instance(target), kind_type) do
      {:ok, authority} ->
        Ezagent.Cap.Authority.with_current(authority, fn -> fun.(authority) end)

      {:error, reason} ->
        raise "test authority open failed: #{inspect(reason)}"
    end
  end

  @doc "Install a fresh target authority in the current ExUnit process."
  @spec install_test_authority!(URI.t(), atom()) :: Ezagent.Cap.Authority.t()
  def install_test_authority!(%URI{} = target, kind_type) when is_atom(kind_type) do
    case Ezagent.Cap.Authority.open(Ezagent.URI.instance(target), kind_type) do
      {:ok, authority} ->
        Process.put({Ezagent.Cap.Authority, :current}, authority)
        authority

      {:error, reason} ->
        raise "test authority open failed: #{inspect(reason)}"
    end
  end

  @doc "Sign an explicit artifact with a test authority already opened for its target."
  @spec authority_signed_cap!(Ezagent.Cap.Authority.t(), URI.t(), Capability.t()) ::
          Capability.t()
  def authority_signed_cap!(authority, %URI{} = grantee, %Capability{} = cap) do
    {:ok, artifact} = Ezagent.Cap.prepare_provenance({:admin, admin_uri()}, grantee, cap)
    Ezagent.Cap.Authority.sign(authority, artifact)
  end

  @doc "Sign an explicit artifact while preserving a concrete fixture issuer."
  @spec authority_signed_cap_as!(
          Ezagent.Cap.Authority.t(),
          URI.t(),
          URI.t(),
          Capability.t()
        ) :: Capability.t()
  def authority_signed_cap_as!(authority, %URI{} = issuer, %URI{} = grantee, %Capability{} = cap) do
    {:ok, artifact} = Ezagent.Cap.prepare_provenance({:held_by, issuer}, grantee, cap)
    Ezagent.Cap.Authority.sign(authority, artifact)
  end

  @doc "Issue a current-generation self-license for a test principal."
  @spec self_license_cap!(URI.t(), atom()) :: Capability.t()
  def self_license_cap!(%URI{} = holder, kind_type \\ :user) when is_atom(kind_type) do
    {:ok, authority} =
      Ezagent.Cap.Authority.open(Ezagent.URI.instance(holder), kind_type, :created)

    requested =
      Ezagent.Capability.cap(
        kind_type,
        Module.concat(["Ezagent", "ActionSet", "Identity"]),
        :self_license,
        Ezagent.URI.instance(holder),
        Ezagent.Capability.workspace_of(holder)
      )

    intent = Ezagent.Cap.Grant.freeze(holder, holder, holder, requested)

    case Ezagent.Cap.Grant.issue_self_license(authority, intent) do
      {:ok, %Capability{} = license} -> license
      {:error, reason} -> raise "test self-license issuance failed: #{inspect(reason)}"
    end
  end

  @doc "Sign every unsigned capability in a test context for one concrete target Kind."
  @spec signed_ctx!(URI.t(), map(), atom()) :: map()
  def signed_ctx!(%URI{} = target, ctx, kind_type \\ :test_fixture) when is_map(ctx) do
    target = target |> Ezagent.URI.instance() |> URI.to_string() |> Ezagent.URI.new!()
    presenter = Map.fetch!(ctx, :caller)

    unless match?(%URI{}, presenter) do
      raise ArgumentError,
            "signed_ctx!/3 requires a concrete URI presenter, got: #{inspect(presenter)}"
    end

    authority = install_test_authority!(target, kind_type)

    caps =
      ctx
      |> Map.get(:caps, MapSet.new())
      |> Enum.map(fn
        %Capability{signature: signature, key_id: key_id} = cap
        when is_binary(signature) and is_binary(key_id) ->
          cap

        %Capability{instance: :any} = cap ->
          # Unified target-generation verification cannot validate an
          # instance-wildcard artifact. This helper promises to sign fixture
          # caps for one concrete target, so concretize the target for every
          # presenter (not only admin). Scope tuples and other deliberately
          # invalid shapes remain untouched and continue to fail closed.
          authority_signed_cap!(authority, presenter, %{cap | instance: target})

        %Capability{} = cap ->
          authority_signed_cap!(authority, presenter, cap)
      end)
      |> MapSet.new()

    caps =
      if MapSet.size(caps) == 0 and presenter == admin_uri() do
        {:ok, anchor} = Ezagent.Cap.Authority.anchor(target)
        MapSet.put(caps, anchor)
      else
        caps
      end

    ctx
    |> Map.put(:authenticated_principal, presenter)
    |> Map.put(:caps, caps)
  end

  @doc "Apply `signed_ctx!/3` to a test invocation's target and context."
  @spec signed_invocation!(Ezagent.Invocation.t(), atom()) :: Ezagent.Invocation.t()
  def signed_invocation!(%Ezagent.Invocation{} = invocation, kind_type \\ :test_fixture) do
    %{invocation | ctx: signed_ctx!(invocation.target, invocation.ctx, kind_type)}
  end

  @doc "Create a target-signed cap for a fixture Kind, including cold-target tests."
  @spec signed_fixture_cap!(URI.t(), atom(), module(), atom(), URI.t()) :: Capability.t()
  def signed_fixture_cap!(%URI{} = target, kind_type, behavior, action, %URI{} = grantee)
      when is_atom(kind_type) and is_atom(behavior) and is_atom(action) do
    {:ok, authority} = Ezagent.Cap.Authority.open(Ezagent.URI.instance(target), kind_type)

    requested =
      Capability.cap(
        kind_type,
        behavior,
        action,
        Ezagent.URI.instance(target),
        Capability.workspace_of(target)
      )

    authority_signed_cap!(authority, grantee, requested)
  end

  @doc "Create the exact target-signed capability declared by a Behavior action."
  @spec signed_required_cap!(URI.t(), atom(), module(), atom(), URI.t()) :: Capability.t()
  def signed_required_cap!(%URI{} = target, kind_type, behavior, action, %URI{} = grantee)
      when is_atom(kind_type) and is_atom(behavior) and is_atom(action) do
    instance = Ezagent.URI.instance(target)
    declared = behavior.required_caps() |> Map.fetch!(action)
    {:ok, authority} = Ezagent.Cap.Authority.open(instance, kind_type)

    requested = %{
      declared
      | kind: if(declared.kind == :any, do: kind_type, else: declared.kind),
        action: action,
        instance: if(declared.instance == :any, do: instance, else: declared.instance),
        workspace_uri:
          if(declared.workspace_uri == :any,
            do: Capability.workspace_of(target),
            else: declared.workspace_uri
          )
    }

    authority_signed_cap!(authority, grantee, requested)
  end

  @doc "Build a target-signed workspace action-wildcard context for a test principal."
  @spec signed_workspace_ctx!(URI.t(), URI.t()) :: map()
  def signed_workspace_ctx!(
        %URI{} = workspace_uri,
        %URI{} = presenter \\ Ezagent.URI.user(:system, :admin)
      ) do
    ensure_workspace_kind!(workspace_uri)

    requested =
      Capability.cap(
        :workspace,
        :any,
        :any,
        Ezagent.URI.instance(workspace_uri),
        workspace_uri
      )

    %{
      caller: presenter,
      authenticated_principal: presenter,
      caps: MapSet.new([signed_cap!(workspace_uri, presenter, requested)])
    }
  end

  @doc "Ensure a concrete Workspace target exists before a real dispatch fixture uses it."
  @spec ensure_workspace_kind!(URI.t()) :: pid()
  def ensure_workspace_kind!(%URI{scheme: "workspace"} = workspace_uri) do
    case Ezagent.KindRegistry.lookup(workspace_uri) do
      {:ok, pid} ->
        pid

      :error ->
        case Ezagent.Kind.spawn(Ezagent.Entity.Workspace, %{
               uri: workspace_uri,
               behaviors: [Ezagent.ActionSet.Workspace]
             }) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @doc "Default test workspace URI: `workspace://system` (admin/system)."
  @spec system_workspace_uri() :: URI.t()
  def system_workspace_uri, do: Ezagent.URI.workspace(:system)

  @doc "Stable tenant test workspace URI: `workspace://team-alpha`."
  @spec tenant_workspace_uri() :: URI.t()
  def tenant_workspace_uri, do: Ezagent.URI.workspace("team-alpha")

  defp admin_uri, do: Ezagent.URI.user(:system, :admin)
  defp default_granter_uri, do: Ezagent.URI.user(:system, :admin)
end

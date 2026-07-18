defmodule Ezagent.ExternalMirror.AuthModelTestHelpers do
  @moduledoc """
  Test ergonomics for `auth_model_invariant_test.exs` (audit SPEC §6.5).

  Provides:

  - `setup_caller/1` — build a `caller_ctx` map with a configurable
    set of caps (no caps / session bind only / + adapter allow /
    admin / cross-workspace).
  - `spawn_owner_and_session/2` — same shape as the existing test
    helper but lives here so the invariant test doesn't reach into
    `behavior/external_mirror_test.exs`.
  - `bypass_facade_dispatch/4` — construct an `Invocation.dispatch/1`
    call that BYPASSES `Ezagent.ExternalMirror.bind/5`. Used by
    scenarios 4, 7, 8, 9, 10 to verify dispatch-side defense in depth
    + the action body's `:bind_must_go_through_facade` refusal.
  - `assert_no_downstream_work/4` — every "denial" scenario asserts
    no downstream observable mutation (no adapter I/O, no DB row,
    no worker, no slice mutation).
  - Counted-adapter mocks via `Process.put/2` counter (SCENARIO_-prefixed
    keys) so each scenario can assert the adapter callback was/wasn't
    called without registering a complex mock per case.
  """

  import ExUnit.Assertions

  alias Ezagent.{Capability, KindRegistry}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.ExternalMirror.{BindingRow, WorkerSpawn}
  alias Ezagent.ExternalMirror.TestSupport.MockPublishAdapter

  @doc """
  Build a caller_ctx with the requested caps profile.

  Profiles:

  - `:admin` — bootstrap admin (`:any/:any/:any` w/ `:any` workspace).
    Passes ALL gates.
  - `:no_caps` — empty MapSet. Fails Gate 1.
  - `:session_bind_only` — only `Behavior.ExternalMirror` `:bind`
    cap on the session. Passes Gate 1, fails Gate 2.
  - `:session_bind_plus_adapter` — Gate 1 + Gate 2. Both pass.
  - `:cross_workspace_admin` — cap with `workspace_uri: :any` that
    bypasses Gate 3 even for cross-workspace target.
  """
  @spec setup_caller(profile :: atom(), Keyword.t()) :: %{
          caller: URI.t(),
          caps: MapSet.t(),
          reply: :ignore
        }
  def setup_caller(profile, opts \\ []) do
    caller_uri =
      Keyword.get_lazy(opts, :caller_uri, fn ->
        Ezagent.URI.user(:default, "inv-#{System.unique_integer([:positive])}")
      end)

    session_uri = Keyword.get(opts, :session_uri)
    workspace_uri = Keyword.get(opts, :workspace_uri, Ezagent.URI.workspace(:default))
    adapter_allow_module = Keyword.get(opts, :adapter_allow, MockPublishAdapter.Allow)

    caps = caps_for_profile(profile, session_uri, workspace_uri, adapter_allow_module)
    ctx = %{caller: caller_uri, caps: caps, reply: :ignore}

    if match?(%URI{}, session_uri) and MapSet.size(caps) > 0 do
      Ezagent.Test.CapHelper.signed_ctx!(session_uri, ctx, :session)
    else
      ctx
    end
  end

  defp caps_for_profile(:admin, _session, _ws, _allow) do
    MapSet.new([
      %Capability{
        kind: :any,
        behavior: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.system(:bootstrap, :default),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }
    ])
  end

  defp caps_for_profile(:no_caps, _session, _ws, _allow), do: MapSet.new()

  defp caps_for_profile(:session_bind_only, %URI{} = session_uri, %URI{} = ws, _allow) do
    MapSet.new([
      %Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.ExternalMirror,
        instance: session_uri,
        workspace_uri: ws,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }
    ])
  end

  defp caps_for_profile(:session_bind_plus_adapter, %URI{} = session_uri, %URI{} = ws, allow) do
    MapSet.new([
      %Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.ExternalMirror,
        instance: session_uri,
        workspace_uri: ws,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      },
      %Capability{
        kind: :session,
        behavior: allow,
        instance: :any,
        workspace_uri: ws,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }
    ])
  end

  defp caps_for_profile(:cross_workspace_admin, _session_uri, _ws, _allow) do
    MapSet.new([
      %Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.ExternalMirror,
        instance: :any,
        workspace_uri: :any,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }
    ])
  end

  @doc """
  Spawn the user + session Kinds (admin caps on the user) and bind
  the session to its workspace in WorkspaceRegistry.
  """
  def spawn_owner_and_session(%URI{} = owner_uri, %URI{} = session_uri) do
    :ok =
      spawn_user(
        owner_uri,
        MapSet.new([Ezagent.Capability.admin_genesis_cap()])
      )

    # `behaviors` is resolved at RUNTIME via `apply/3`: this app deliberately
    # does NOT depend on `:ezagent_domain_session` (a deps cycle —
    # see mix.exs), so `Ezagent.Entity.Session` is undefined at COMPILE time
    # in this `.ex` support module. A direct `Session.behaviors()` would emit
    # an "undefined function" warning that the FF-3 dead-code gate (`mix
    # compile --warnings-as-errors`) hard-fails on. The module IS loaded at
    # test-run time in the umbrella, so `apply/3` resolves it then.
    case Ezagent.Kind.spawn(Session, %{
           uri: session_uri,
           owner_uri: owner_uri,
           behaviors: apply(Session, :behaviors, [])
         }) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    ws = Ezagent.Capability.workspace_of(session_uri)

    case ws do
      %URI{} = ws_uri -> :ok = Ezagent.WorkspaceRegistry.bind(session_uri, ws_uri)
      :any -> :ok
    end

    await_session_alive(session_uri, 50)
  end

  defp spawn_user(%URI{} = user_uri, caps) do
    case Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: caps}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      # Concurrent / sequential test invocations might race on the
      # KindRegistry put_new (`Kind.spawn` returning
      # `{:already_registered, _uri}`). Already-registered for a
      # User Kind is functionally the same as already-started.
      {:error, {:already_registered, _uri}} -> :ok
    end

    :ok
  end

  defp await_session_alive(_uri, 0), do: {:error, :timeout}

  defp await_session_alive(uri, retries) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        case Ezagent.ReadyGate.status(URI.to_string(uri)) do
          :ready -> :ok
          _ -> Process.sleep(20) && await_session_alive(uri, retries - 1)
        end

      _ ->
        Process.sleep(20)
        await_session_alive(uri, retries - 1)
    end
  end

  @doc """
  Cleanup session by terminating its child of EzagentDomainInstanceMessage.SessionSupervisor.
  """
  def cleanup_session(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Build an `Invocation.dispatch/1` call that BYPASSES the facade.
  Scenarios 4, 7, 8, 9, 10 use this to assert dispatch-side defenses
  + the action body's `:bind_must_go_through_facade` refusal.
  """
  def bypass_facade_dispatch(session_uri, adapter_id, target_id, args_overrides, ctx) do
    target =
      Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=external_mirror.bind")

    base_args = %{
      adapter_id: adapter_id,
      target_id: target_id,
      opts: %{}
    }

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: Map.merge(base_args, args_overrides),
      ctx: ctx,
      origin: :trusted_internal
    }

    Ezagent.Invocation.dispatch(inv)
  end

  @doc """
  Assert that NO downstream observable mutation happened. Per SPEC §6.3:

  1. Adapter I/O did NOT fire (target_ownership_check counter == 0).
  2. DB row NOT written.
  3. Worker NOT in `KindRegistry`.
  4. Slice NOT mutated (no binding for this triple).
  """
  def assert_no_downstream_work(session_uri, adapter_id, target_id, opts \\ []) do
    assert_no_adapter_io = Keyword.get(opts, :assert_no_adapter_io, true)
    counter_key = Keyword.get(opts, :counter_key, {:target_check, adapter_id, target_id})

    if assert_no_adapter_io do
      count = Process.get(counter_key, 0)

      assert count == 0,
             "expected adapter target_ownership_check call count == 0 for " <>
               "(#{adapter_id}, #{inspect(target_id)}), got #{count}"
    end

    # No DB row for (adapter_id, target_id) on this session
    rows = BindingRow.list_for_session(session_uri)

    matching =
      Enum.filter(rows, fn row ->
        row.adapter_id == adapter_id and row.target_id == inspect(target_id)
      end)

    assert matching == [],
           "expected no DB row for (#{adapter_id}, #{inspect(target_id)}); got #{inspect(matching)}"

    # No worker in KindRegistry
    worker_uri = WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id)

    case KindRegistry.lookup(worker_uri) do
      :error ->
        :ok

      {:ok, pid} ->
        flunk("expected no worker for #{inspect(worker_uri)}; got pid #{inspect(pid)}")
    end

    # No slice mutation
    case Ezagent.Kind.get_slice(session_uri, :external_mirror) do
      {:ok, slice} ->
        refute Enum.any?(
                 slice.bindings,
                 &(&1.adapter_id == adapter_id and &1.target_id == target_id)
               ),
               "expected slice to have no binding for (#{adapter_id}, #{inspect(target_id)}); " <>
                 "slice.bindings=#{inspect(slice.bindings)}"

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Returns a unique session URI under the given workspace (default
  `workspace://default`).
  """
  def unique_session_uri(prefix, workspace \\ "default") do
    Ezagent.URI.session(workspace, :default, "#{prefix}-#{System.unique_integer([:positive])}")
  end

  @doc "Returns a unique caller URI under the given workspace."
  def unique_user_uri(prefix, workspace \\ "default") do
    Ezagent.URI.user(workspace, "#{prefix}-#{System.unique_integer([:positive])}")
  end
end

defmodule Ezagent.ActionSet.IdentityLifecycleColdLoadTest do
  @moduledoc """
  Phase B architectural-goal gate (SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6) for the
  STATE-ONLY identity Behaviors converted to `use Ezagent.Lifecycle`.

  The five identity modules (`ApiKeys`, `Identity`/`IdentityAdmin`,
  `UserCredentials`, `UserTokens`, `WorkspaceUserAdmin`) have NO transients —
  so the `assert_transients_rebuilt/2` gate (which REQUIRES a non-empty
  `transients` container) does not apply. The architectural invariant that
  DOES apply to a state-only Lifecycle module is the create-once + cold-load
  rehydrate contract (SPEC §3 / §9 OQ-1):

  - `create/1` runs EXACTLY ONCE in the entity's history (gated by the
    durable `kind_snapshots.ever_created` marker). A cold restart must NOT
    re-run it — if it did, the persisted state (here `ApiKeys` keys) would be
    silently reset to the `create/1` empty default, and the
    `ever_created?` marker would prove the regression.
  - The persistent `state` (and ONLY `state`) survives a brutal kill +
    demand re-spawn from the snapshot.

  This test FAILS exactly when that bug class reappears: a `create/1` that is
  wrongly re-run on cold-load (wiping persisted state) or a persistent field
  that did not survive the restart.

  It also exercises `Ezagent.ActionSet.Identity.activate/2` — the caps_json
  reconcile folded out of the old `post_init/2` + `handle_continue/3` (OQ-8)
  — by asserting the caps re-read from `users.caps_json` is unioned into the
  rehydrated `:identity` state on a cold restart.
  """

  use Ezagent.LifecycleCase, async: false

  import EzagentDomainIdentity.CapSigningTestHelpers

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Invocation

  # ----------------------------------------------------------------------
  # Host Kinds for the test. {:snapshot, :on_change} so persistent `state`
  # survives a cold restart (and a wrongly-rerun `create/1` would be caught).
  # ----------------------------------------------------------------------

  defmodule ApiKeysHostKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :identity_lifecycle_apikeys_host
    @impl true
    def behaviors, do: [Ezagent.ActionSet.ApiKeys]
    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  defmodule IdentityHostKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :identity_lifecycle_identity_host
    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity]
    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  # `use Ezagent.LifecycleCase` (async: false) already starts a SHARED
  # sandbox owner via EzagentCore.DataCase.setup_sandbox/1 — so the
  # Kind.Server process (which runs the snapshot persist + Identity's
  # caps_json reconcile in a SEPARATE process) sees this test's transaction.
  setup do
    :ok =
      Ezagent.BehaviorRegistry.register(ApiKeysHostKind, :put_api_key, Ezagent.ActionSet.ApiKeys)

    :ok =
      Ezagent.BehaviorRegistry.register(ApiKeysHostKind, :get_api_key, Ezagent.ActionSet.ApiKeys)

    :ok
  end

  defp unique_agent_uri do
    URI.new!("entity://cold-load/agent/curl_agent-#{System.unique_integer([:positive])}")
  end

  describe "THE GATE (state-only) — cold restart rehydrates state + does NOT re-run create/1" do
    test "ApiKeys: a key set via dispatch survives a brutal kill + respawn; create is not re-run" do
      uri = unique_agent_uri()
      uri_str = URI.to_string(uri)

      {:ok, pid1} = Ezagent.Kind.spawn(ApiKeysHostKind, %{uri: uri})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # create/1 ran once: empty keys. The ever-created marker is now set.
      {:ok, %{state: state0, transients: tr0}} = Ezagent.Kind.get_raw_slice(uri, :api_keys)
      assert state0.keys == %{}
      # STATE-ONLY: the transients container is empty (no activate rebuild).
      assert tr0 == %{}
      assert KindSnapshot.ever_created?(uri_str)

      # Drive a NON-TRIVIAL persistent state via dispatch (a {:set, :keys, _}).
      put_target = URI.new!("#{uri_str}?action=api_keys.put_api_key")

      assert {:ok, %{ok: true, provider: "deepseek"}} =
               Invocation.dispatch(%Invocation{
                 target: put_target,
                 mode: :call,
                 args: %{provider: "deepseek", key: "sk-aaaabbbbccccdddd"},
                 ctx: %{caller: :vm_internal, caps: MapSet.new(), reply: {:caller_inbox, self()}}
               })

      {:ok, %{state: state1}} = Ezagent.Kind.get_raw_slice(uri, :api_keys)
      assert state1.keys == %{"deepseek" => "sk-aaaabbbbccccdddd"}

      # Brutal kill (skips graceful deactivate/destroy) — only the durable
      # `state` survives. The :permanent Kind.Server auto-restarts at the URI.
      Process.exit(pid1, :kill)

      wait_until(fn ->
        case Ezagent.KindRegistry.lookup(uri) do
          {:ok, p} when p != pid1 -> Ezagent.ReadyGate.status(uri) == :ready
          _ -> false
        end
      end)

      {:ok, pid2} = Ezagent.KindRegistry.lookup(uri)
      refute pid1 == pid2

      {:ok, %{state: state2, transients: tr2}} = Ezagent.Kind.get_raw_slice(uri, :api_keys)

      # 1. Persistent state rehydrated from the snapshot.
      assert state2.keys == %{"deepseek" => "sk-aaaabbbbccccdddd"},
             "cold-load did not rehydrate persisted ApiKeys state — either the snapshot " <>
               "was not written or create/1 was WRONGLY re-run (which would reset keys to %{})"

      # 2. create/1 was NOT re-run: the ever-created marker stayed set across
      #    the restart, and the rehydrated keys are the dispatched ones (a
      #    re-run create would have produced %{}).
      assert KindSnapshot.ever_created?(uri_str)
      # 3. STATE-ONLY: still no transients after the cold-load activate no-op.
      assert tr2 == %{}

      Ezagent.Kind.terminate(uri)
    end
  end

  describe "Identity.activate/2 — caps_json reconcile (OQ-8) runs on every start" do
    test "a cap in users.caps_json is unioned into :identity state on boot (folded from post_init)" do
      # Provision a real user whose users.caps_json carries a cap that is
      # NOT in the spawn's `initial_caps` — so the ONLY way it can appear in
      # the `:identity` state is via the activate/2 reconcile (the folded
      # post_init/handle_continue caps_json re-read, OQ-8).
      handle = "cold-reconcile-#{System.unique_integer([:positive])}"
      user_uri = URI.new!("entity://cold-load/user/#{handle}")

      # A concrete granter URI is required so the cap encodes into
      # users.caps_json (the default `:plugin_declared` granter is not a URI).
      extra_cap =
        Ezagent.Capability.cap(
          :session,
          Ezagent.ActionSet.Session,
          :send,
          :any,
          Ezagent.Capability.workspace_of(user_uri)
        )
        |> Map.put(:granted_by, URI.new!("entity://system/user/admin"))
        |> Map.put(:granted_at, DateTime.utc_now())

      {:ok, _decoded} = Ezagent.Users.create(user_uri, nil, [issue!(user_uri, extra_cap)])

      :ok =
        Ezagent.BehaviorRegistry.register(
          IdentityHostKind,
          :list_caps,
          Ezagent.ActionSet.Identity
        )

      # Spawn with EMPTY initial_caps → create/1 yields only the owner
      # self-Identity cap. The Chat.send cap can only be present if
      # activate/2 reconciled it from users.caps_json.
      {:ok, _pid} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: user_uri, initial_caps: []})
      wait_until(fn -> Ezagent.ReadyGate.status(user_uri) == :ready end)

      {:ok, %{state: state0}} = Ezagent.Kind.get_raw_slice(user_uri, :identity)

      assert Enum.any?(state0.caps, fn c ->
               c.behavior == Ezagent.ActionSet.Session and c.action == :send
             end),
             "Identity.activate/2 did not reconcile the users.caps_json Chat.send cap into " <>
               "the :identity state — the folded post_init/handle_continue reconcile did not run"

      Ezagent.Kind.terminate(user_uri)
    end

    test "I5 caps_json reconcile drops an unverified cap before union" do
      handle = "cold-reconcile-invalid-#{System.unique_integer([:positive])}"
      user_uri = URI.new!("entity://cold-load/user/#{handle}")

      invalid_cap =
        Ezagent.Capability.cap(
          :session,
          Ezagent.ActionSet.Session,
          :send,
          :any,
          Ezagent.Capability.workspace_of(user_uri)
        )
        |> Map.put(:granted_by, URI.new!("system://forged"))
        |> Map.put(:granted_at, DateTime.utc_now())

      _decoded = create_legacy_user!(user_uri, nil, [invalid_cap])

      :ok =
        Ezagent.BehaviorRegistry.register(
          IdentityHostKind,
          :list_caps,
          Ezagent.ActionSet.Identity
        )

      {:ok, _pid} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: user_uri, initial_caps: []})
      wait_until(fn -> Ezagent.ReadyGate.status(user_uri) == :ready end)

      {:ok, %{state: state0}} = Ezagent.Kind.get_raw_slice(user_uri, :identity)

      refute Enum.any?(state0.caps, fn cap ->
               cap.behavior == Ezagent.ActionSet.Session and cap.action == :send
             end)

      Ezagent.Kind.terminate(user_uri)
    end
  end
end

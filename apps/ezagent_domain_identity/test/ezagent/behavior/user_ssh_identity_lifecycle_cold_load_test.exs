defmodule Ezagent.ActionSet.UserSshIdentityLifecycleColdLoadTest do
  @moduledoc """
  I3 (Task 1 review, both Claude + Codex independently) — no test
  previously drove `UserSshIdentity` through a real Kind process:
  registration, effect application, snapshot commit, cold-restart reload,
  and CapBAC were all unverified. Every test in `user_ssh_identity_test.exs`
  calls `handle_generate_ssh_key/2` directly against a fake `ctx[:read]`
  function — a regression in any of those five things (a `{:set, ...}`
  write landing in the wrong container, a missed boot registration, a
  cold-load that drops the new slice, an authz bypass) would leave every
  one of those tests green.

  Mirrors `identity_lifecycle_cold_load_test.exs`'s ApiKeys pattern (SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6,
  state-only variant): `UserSshIdentity` has no transients either (see its
  moduledoc), so `Ezagent.LifecycleCase.assert_transients_rebuilt/2`'s
  non-empty-transients requirement doesn't apply — this hand-rolls the same
  kill+respawn shape ApiKeys' gate uses, for the same reason.

  Spawns a real Kind hosting the real `Ezagent.ActionSet.UserSshIdentity`,
  dispatches `:generate_ssh_key` through the actual signed-cap
  `Invocation.dispatch/1` path (exercising CapBAC — an unsigned or
  wrongly-shaped cap fails before `handle_generate_ssh_key/2` ever runs),
  reads the persisted private key back from the raw slice, brutal-kills the
  process, waits for the supervisor's demand-respawn, and asserts the
  private key survived the cold load byte-for-byte — then asserts a second
  `generate_ssh_key` dispatch is refused (proving `create/1` was NOT
  wrongly re-run, which would have reset the slice to empty and let the
  retry silently succeed).
  """

  use Ezagent.LifecycleCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_invocation!: 2, signed_required_cap!: 5]

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Invocation

  defmodule UserSshIdentityHostKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :identity_lifecycle_sshkey_host
    @impl true
    def behaviors, do: [Ezagent.ActionSet.UserSshIdentity]
    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  # `use Ezagent.LifecycleCase` (async: false) already starts a SHARED
  # sandbox owner via EzagentCore.DataCase.setup_sandbox/1 — so the
  # Kind.Server process (which runs the snapshot persist in a SEPARATE
  # process) sees this test's transaction.
  setup do
    :ok =
      Ezagent.BehaviorRegistry.register(
        UserSshIdentityHostKind,
        :generate_ssh_key,
        UserSshIdentity
      )

    :ok
  end

  defp unique_user_uri do
    URI.new!("entity://cold-load/user/sshkey_user-#{System.unique_integer([:positive])}")
  end

  defp dispatch!(target, args, cap, admin) do
    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    }
    |> signed_invocation!(:identity_lifecycle_sshkey_host)
    |> Invocation.dispatch()
  end

  describe "THE GATE (state-only) — real dispatch -> persistent state -> cold restart survives" do
    test "generate_ssh_key via dispatch persists the private key through a brutal kill + respawn" do
      uri = unique_user_uri()
      uri_str = URI.to_string(uri)

      {:ok, pid1} = Ezagent.Kind.spawn(UserSshIdentityHostKind, %{uri: uri})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # create/1 ran once: no identity yet. The ever-created marker is now set.
      {:ok, %{state: state0, transients: tr0}} =
        Ezagent.Kind.SliceAccess.get_raw_slice(uri, :user_ssh_identity)

      refute Map.get(state0, :private_key)
      refute Map.get(state0, :public_key)
      # STATE-ONLY: the transients container is empty (no activate rebuild).
      assert tr0 == %{}
      assert KindSnapshot.ever_created?(uri_str)

      # Real dispatch through the actual signed-cap path — THIS is the
      # CapBAC exercise. An unsigned or wrongly-shaped cap fails
      # Invocation.dispatch/1 before handle_generate_ssh_key/2 ever runs.
      target = URI.new!("#{uri_str}?action=user_ssh_identity.generate_ssh_key")
      admin = Ezagent.URI.user(:system, :admin)

      cap =
        signed_required_cap!(
          target,
          :identity_lifecycle_sshkey_host,
          UserSshIdentity,
          :generate_ssh_key,
          admin
        )

      assert {:ok, %{public_key: pub, fingerprint: fp}} =
               dispatch!(target, %{comment: "cold-load-test"}, cap, admin)

      assert String.starts_with?(pub, "ssh-ed25519 ")
      assert is_binary(fp) and fp != ""

      {:ok, %{state: state1}} =
        Ezagent.Kind.SliceAccess.get_raw_slice(uri, :user_ssh_identity)

      assert state1.public_key == pub
      assert state1.fingerprint == fp
      assert is_binary(state1.private_key)
      assert String.starts_with?(state1.private_key, "-----BEGIN OPENSSH PRIVATE KEY-----")

      private_before = state1.private_key

      # Brutal kill (skips graceful deactivate/destroy) — only the durable
      # `state` survives. The :permanent Kind.Server auto-restarts at the
      # same URI.
      Process.exit(pid1, :kill)

      wait_until(fn ->
        case Ezagent.KindRegistry.lookup(uri) do
          {:ok, p} when p != pid1 -> Ezagent.ReadyGate.status(uri) == :ready
          _ -> false
        end
      end)

      {:ok, pid2} = Ezagent.KindRegistry.lookup(uri)
      refute pid1 == pid2, "cold restart must produce a new pid"

      {:ok, %{state: state2, transients: tr2}} =
        Ezagent.Kind.SliceAccess.get_raw_slice(uri, :user_ssh_identity)

      # 1. The private key survived the cold load byte-for-byte.
      assert state2.private_key == private_before,
             "cold-load did not rehydrate the persisted private key — either the " <>
               "snapshot was not written, or create/1 was WRONGLY re-run (which would " <>
               "have reset the slice to empty)"

      assert state2.public_key == pub
      assert state2.fingerprint == fp

      # 2. create/1 was NOT re-run: the ever-created marker stayed set
      #    across the restart.
      assert KindSnapshot.ever_created?(uri_str)

      # 3. Proof create/1 wasn't silently re-run in a way ( 1) alone can't
      #    rule out: the existence guard in handle_generate_ssh_key/2 reads
      #    the SAME rehydrated state, so a second dispatch must still
      #    refuse. A wrongly-reset slice would let this succeed instead.
      retry_cap =
        signed_required_cap!(
          target,
          :identity_lifecycle_sshkey_host,
          UserSshIdentity,
          :generate_ssh_key,
          admin
        )

      assert {:error, :ssh_identity_exists} = dispatch!(target, %{}, retry_cap, admin)

      # 4. STATE-ONLY: still no transients after the cold-load activate no-op.
      assert tr2 == %{}

      Ezagent.Kind.terminate(uri)
    end
  end
end

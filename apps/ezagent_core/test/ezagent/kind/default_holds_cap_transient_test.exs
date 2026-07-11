defmodule Ezagent.Kind.DefaultHoldsCapTransientTest do
  @moduledoc """
  Regression gate for the fail-closed-wrongly CapBAC bug: a TRANSIENT failure to
  read an entity's `:identity` slice must NEVER be silently converted into a
  capability DENIAL.

  The historical `default_holds_cap?/2` collapsed every non-`{:ok, caps}`
  `get_slice` outcome into a single `_ -> false` deny. Under a starved Ecto
  sandbox pool (CI) — or a production Kind restart / DB failover — a transient
  read failure (the identity Kind alive-but-blocked, or briefly un-registered
  while its durable snapshot survives) became a spurious `:unauthorized`.

  These tests pin the four outcomes DISTINCTLY, and are written so a revert to
  `_ -> false` (or any successor that denies on a transient) FAILS:

  - transient `{:get_slice_exit, _}` (alive but unreadable) → RAISES (not deny)
  - `:not_found` + durable snapshot (KNOWN but cold) → RAISES (not deny)
  - `:not_found` + NO durable snapshot (genuinely non-existent) → clean `false`
    (the security-critical control against opening a bypass)
  - `{:ok, caps}` → matches → `true`; no match → `false` (happy path preserved)

  Per `feedback_completion_requires_invariant_test` +
  `feedback_reproduce_failure_before_component_benchmarks`.
  """
  use EzagentCore.DataCase, async: false

  @moduletag :umbrella_only

  alias Ezagent.{Capability, Kind, Users}
  alias Ezagent.Kind.IdentityReadError

  # A concrete NEEDED cap (session.send). `default_holds_cap?/2` builds the
  # needed-map internally.
  @needed %Capability{
    kind: :session,
    behavior: Ezagent.ActionSet.Session,
    action: :send,
    instance: :any,
    workspace_uri: :any,
    granted_by: nil,
    granted_at: ~U[2026-01-01 00:00:00Z]
  }

  # An entity-granted wildcard held cap — matches ANY needed cap AND passes #154
  # predicate A (`granted_by_entity?`).
  defp matching_held do
    %Capability{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: ~U[2026-01-01 00:00:00Z]
    }
  end

  defp unique, do: System.unique_integer([:positive])

  setup do
    # Keep the bounded retry fast + deterministic for the transient tests.
    prev = %{
      timeout: Application.get_env(:ezagent_core, :identity_read_timeout_ms),
      attempts: Application.get_env(:ezagent_core, :identity_read_max_attempts),
      backoff: Application.get_env(:ezagent_core, :identity_read_backoff_ms)
    }

    Application.put_env(:ezagent_core, :identity_read_timeout_ms, 80)
    Application.put_env(:ezagent_core, :identity_read_max_attempts, 3)
    Application.put_env(:ezagent_core, :identity_read_backoff_ms, 5)

    on_exit(fn ->
      restore(:identity_read_timeout_ms, prev.timeout)
      restore(:identity_read_max_attempts, prev.attempts)
      restore(:identity_read_backoff_ms, prev.backoff)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ezagent_core, key)
  defp restore(key, val), do: Application.put_env(:ezagent_core, key, val)

  describe "transient identity-read failures fail LOUD (never a silent deny)" do
    test "get_slice EXIT (Kind alive but unreadable) RAISES, does not return false" do
      uri = Ezagent.URI.new!("entity://team-alpha/user/transient_exit_#{unique()}")
      parent = self()

      # A plain process that OWNS the KindRegistry entry but never answers the
      # `{:ezagent_get_slice, _}` GenServer.call — reproduces the "identity Kind
      # is alive but its call times out under pool starvation / mid-restart"
      # transient, which `get_slice/3` surfaces as `{:error, {:get_slice_exit, _}}`.
      dummy =
        spawn(fn ->
          :ok = Ezagent.KindRegistry.put_new(uri)
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered, 1_000
      on_exit(fn -> Process.exit(dummy, :kill) end)

      assert_raise IdentityReadError, fn ->
        Kind.default_holds_cap?(uri, @needed)
      end
    end

    test "':not_found' but a DURABLE snapshot exists (KNOWN but cold) RAISES, not false" do
      uri = Ezagent.URI.new!("entity://team-alpha/user/cold_durable_#{unique()}")

      # Persist a durable Kind snapshot WITHOUT a live Kind — exactly what a Kind
      # restart / rehydration window looks like: no live pid, durable identity
      # survives. The read must classify this transient, not absent.
      :ok =
        Ezagent.Test.SnapshotFixtures.save_kind_snapshot(
          uri,
          Ezagent.Entity.User,
          %{identity: %{caps: MapSet.new()}}
        )

      assert_raise IdentityReadError, fn ->
        Kind.default_holds_cap?(uri, @needed)
      end
    end
  end

  describe "genuine denials stay clean (false), not raised — the authz-hole control" do
    test "a genuinely non-existent entity (:not_found, NO durable snapshot) denies cleanly" do
      uri = Ezagent.URI.new!("entity://team-alpha/user/ghost_#{unique()}")

      # No live Kind, no users row, no snapshot → the entity does not exist.
      # This MUST deny cleanly (false) and MUST NOT be treated as transient —
      # otherwise every probe of an unknown URI would crash (and, worse, could
      # open a retry bypass).
      assert Kind.default_holds_cap?(uri, @needed) == false
    end

    test "a live entity whose caps do NOT match the needed cap denies cleanly (false)" do
      uri_str = "entity://team-alpha/user/live_nomatch_#{unique()}"
      {:ok, _} = Users.create(uri_str, nil, [])
      uri = Ezagent.URI.new!(uri_str)
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

      assert Kind.default_holds_cap?(uri, @needed) == false
    end
  end

  describe "happy path preserved" do
    test "a live entity holding a matching entity-granted cap IS authorized (true)" do
      uri_str = "entity://team-alpha/user/live_match_#{unique()}"
      {:ok, _} = Users.create(uri_str, nil, [matching_held()])
      uri = Ezagent.URI.new!(uri_str)
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

      assert Kind.default_holds_cap?(uri, @needed) == true
    end
  end

  describe "dispatch chokepoint surfaces the transient as a distinct, non-denial error" do
    # End-to-end at the step-5.5 chokepoint (`Kind.Runtime.authz_check`): a
    # transient CALLER identity-read must NOT crash the TARGET (the session), and
    # must NOT be the security decision `:unauthorized` — it is the distinct,
    # caller-retryable `:identity_read_unavailable`.
    test "a transient caller identity-read yields :identity_read_unavailable, not :unauthorized, and does NOT crash the target session" do
      # A session TARGET (alive, owned by admin).
      short = "transient_disp_#{unique()}"

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(
          short,
          Ezagent.Entity.User.admin_uri(),
          template_name: "default"
        )

      {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

      # A CALLER whose identity Kind is alive-but-unreadable (owns its registry
      # entry, never answers the get_slice call).
      caller = Ezagent.URI.new!("entity://team-alpha/user/transient_caller_#{unique()}")
      parent = self()

      dummy =
        spawn(fn ->
          :ok = Ezagent.KindRegistry.put_new(caller)
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered, 1_000
      on_exit(fn -> Process.exit(dummy, :kill) end)

      send_target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")

      msg =
        Ezagent.Message.new(caller, %{text: "x", attachments: []}, mentions: [], ref_id: nil)

      # Empty ctx.caps → path-1 misses → path-2 (holds_cap on the transient
      # caller) → IdentityReadError raised inside default_holds_cap? → chokepoint
      # converts it to the distinct retryable error.
      result =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: send_target,
          mode: :call,
          args: %{message: msg},
          ctx: %{caller: caller, caps: MapSet.new(), reply: :inline}
        })

      assert result == {:error, :identity_read_unavailable},
             "a transient caller identity-read must surface as :identity_read_unavailable, not #{inspect(result)}"

      refute match?({:error, :unauthorized}, result),
             "it must NEVER be a denial — a transient is not a security decision"

      # The TARGET session survived — the transient did not crash it.
      assert Process.alive?(session_pid),
             "the target session must NOT crash when the CALLER's identity read is transient"
    end
  end
end

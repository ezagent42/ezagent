defmodule Ezagent.Invariants.NoSandboxOwnerNoiseTest do
  @moduledoc """
  #52 GATE (G1). The architectural goal of the test-isolation-race fix is
  *"no DB work runs without a sandbox owner in the test env."* This gate
  asserts on the ABSENCE of the tell-tale log lines that prove the goal is
  violated — so a fix that merely widens a `rescue` or sleeps cannot pass.

  We capture logs over a REPRESENTATIVE op: demand-spawn the
  `system://routing/default` sentinel (the Mode-B boot-singleton, now
  spawned inside an owned sandbox connection instead of at boot) and run a
  `Behavior.Routing` dispatch through it — the exact path that, pre-fix,
  emitted `cannot find ownership process` / `snapshot_exists?: … raised` /
  `EventLog.append failed` / `database is locked`. With the boot-spawn
  gated out of `:test` and the Kind spawned + allowed onto the test owner,
  NONE of those lines may appear.

  Cross-tier: the dispatch resolves `EzagentDomainInstanceMessage.Routing.MentionRouting`,
  so this suite is umbrella-only.
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  import ExUnit.CaptureLog

  alias Ezagent.{Invocation, Routing.Matcher}
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  @noise_patterns [
    "cannot find ownership process",
    "snapshot_exists?",
    "EventLog.append failed",
    "database is locked",
    "DBConnection.OwnershipError"
  ]

  test "demand-spawning + dispatching to the routing sentinel emits no sandbox-owner noise" do
    uri = Ezagent.Entity.System.routing_default_uri()

    if match?({:ok, _pid}, Ezagent.KindRegistry.lookup(uri)) do
      :ok = Ezagent.Kind.terminate(uri)
      wait_until_gone(uri)
    end

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(uri)
    end)

    log =
      capture_log(fn ->
        # Demand-spawn the Mode-B singleton inside the owned sandbox.
        case Ezagent.SpawnRegistry.spawn(uri) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

        {:ok, pid} = Ezagent.KindRegistry.lookup(uri)
        # `allow/3` returns `:ok`, or `{:already, :allowed | :owner}` if the
        # Kind survived a prior test (the sentinel is reused across the
        # suite); both mean "owned", so accept either.
        _ = Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), pid)

        # Representative DB-touching dispatch (snapshot write + rule insert).
        matcher = Matcher.text_contains("g1-noise-#{System.unique_integer([:positive])}")
        target = Ezagent.URI.with_action(uri, :routing, :add_rule)
        presenter = Ezagent.Entity.User.admin_uri()

        cap =
          signed_fixture_cap!(
            uri,
            Ezagent.Entity.System.type_name(),
            Ezagent.ActionSet.Routing,
            :add_rule,
            presenter
          )

        {:ok, %{id: id}} =
          Invocation.dispatch(%Invocation{
            origin: :trusted_internal,
            target: target,
            mode: :call,
            args: %{
              table: MentionRouting,
              matcher_json: Matcher.to_json(matcher),
              receivers: ["session://team-alpha/default/g1-rcv"]
            },
            ctx: %{
              caller: presenter,
              caps: MapSet.new([cap]),
              reply: {:caller_inbox, self()}
            }
          })

        assert is_integer(id)

        # Drain the sentinel so any async snapshot write completes against
        # the still-owned connection (mirrors DataCase teardown drain).
        _ = GenServer.call(pid, :ezagent_kind_module, 5_000)
      end)

    for pattern <- @noise_patterns do
      refute log =~ pattern,
             """
             #52 G1 violated: the representative routing demand-spawn +
             dispatch emitted a sandbox-owner noise line matching
             #{inspect(pattern)}. That means DB work ran without a sandbox
             owner (or a write hit a lock) — the ownership-coverage gap the
             test-isolation-race fix is supposed to close has regressed.

             Captured log:
             #{log}
             """
    end
  end

  defp wait_until_gone(uri, attempts \\ 100)
  defp wait_until_gone(_uri, 0), do: flunk("routing sentinel did not terminate")

  defp wait_until_gone(uri, attempts) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> Process.sleep(5) && wait_until_gone(uri, attempts - 1)
    end
  end
end

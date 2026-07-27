defmodule Ezagent.Kind.ServerPostInitPersistentTest do
  @moduledoc """
  PR-EM-CORE codex round-1 MEDIUM-1 regression — verify that a
  `{:snapshot, :on_change}` Kind whose post-init `handle_continue/3`
  returns `{:ok, new_slice}` durably persists the mutation (without
  this the in-memory slice would be lost on restart).

  Separated from `Ezagent.Kind.ServerPostInitTest` because this case
  needs the Ecto sandbox via `EzagentCore.DataCase`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.TestSupport.{PersistentPostInitBehavior, PersistentPostInitKind}

  test "post-init slice mutation is durably snapshotted for :on_change Kind" do
    suffix = System.unique_integer([:positive])
    uri = Ezagent.URI.new!("entity://team-alpha/agent/test_persistent_post_init-#{suffix}")
    uri_str = URI.to_string(uri)

    :ok =
      Ezagent.BehaviorRegistry.register(
        PersistentPostInitKind,
        :noop,
        PersistentPostInitBehavior
      )

    {:ok, pid} =
      Ezagent.Kind.Server.start_link({PersistentPostInitKind, %{uri: uri}})

    # Wait for :ready + the post-init handle_continue/3 to write back.
    :ok = wait_until(fn -> Ezagent.ReadyGate.status(uri_str) == :ready end, 500)

    # Wait until the post-init slice mutation lands in the live state.
    :ok =
      wait_until(
        fn ->
          case Ezagent.Kind.read(uri_str, :persistent, spawn: :never) do
            {:ok, %{post_init_value: :written_by_post_init}} -> true
            _ -> false
          end
        end,
        500
      )

    # And, the codex round-1 MEDIUM-1 invariant: the post-init slice
    # write is DURABLE — a `kind_snapshots` row exists with the
    # new slice value. Without the `commit_post_init/2` route through
    # `Ezagent.Kind.Snapshot.commit/4` this row would not exist and
    # a restart would lose `post_init_value: :written_by_post_init`.
    :ok =
      wait_until(
        fn ->
          case KindSnapshot.get(uri_str) do
            nil ->
              false

            row ->
              case KindSnapshot.decode_state(row) do
                {:ok, %{persistent: %{post_init_value: :written_by_post_init}}} -> true
                _ -> false
              end
          end
        end,
        500
      )

    assert Process.alive?(pid)
  end

  defp wait_until(check, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(check, deadline)
  end

  defp poll(check, deadline) do
    if check.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(5)
        poll(check, deadline)
      end
    end
  end
end

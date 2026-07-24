defmodule Ezagent.Persistence.TransientRetryTest do
  use ExUnit.Case, async: true

  alias Ezagent.Persistence.TransientRetry

  defp counting_fun(counter, fail_until, fail_error, ok_value) do
    fn ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      if n < fail_until, do: raise(fail_error), else: ok_value
    end
  end

  test "retries a transient DBConnection.ConnectionError and returns the eventual success" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    fail = %DBConnection.ConnectionError{message: "owner exited"}

    assert TransientRetry.with_retry(counting_fun(counter, 2, fail, :ok)) == :ok
    assert Agent.get(counter, & &1) == 3
  end

  test "retries a transient DBConnection.OwnershipError (test-Sandbox owner-exit race)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    fail = %DBConnection.OwnershipError{message: "cannot find ownership process"}

    assert TransientRetry.with_retry(counting_fun(counter, 1, fail, {:ok, :recovered})) ==
             {:ok, :recovered}

    assert Agent.get(counter, & &1) == 2
  end

  test "retries a transient Postgrex.Error (deadlock_detected)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    fail = %Postgrex.Error{postgres: %{code: :deadlock_detected}}

    assert TransientRetry.with_retry(counting_fun(counter, 1, fail, :ok)) == :ok
  end

  test "does not retry a non-transient error — reraises on the first attempt" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert_raise ArgumentError, "boom", fn ->
      TransientRetry.with_retry(fn ->
        Agent.update(counter, &(&1 + 1))
        raise ArgumentError, "boom"
      end)
    end

    assert Agent.get(counter, & &1) == 1
  end

  test "does not retry a non-transient Postgrex error (e.g. a constraint violation)" do
    # Postgrex.Error.message/1 dot-accesses severity/pg_code/code/message on the
    # `postgres` map, so the fixture needs all four or assert_raise's own
    # Exception.message/1 call (unrelated to what this test checks) crashes.
    postgres = %{
      severity: "ERROR",
      pg_code: "23505",
      code: :unique_violation,
      message: "duplicate key value violates unique constraint"
    }

    assert_raise Postgrex.Error, fn ->
      TransientRetry.with_retry(fn -> raise %Postgrex.Error{postgres: postgres} end)
    end
  end

  test "exhausts the retry budget and reraises the last transient error" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert_raise DBConnection.OwnershipError, fn ->
      TransientRetry.with_retry(fn ->
        Agent.update(counter, &(&1 + 1))
        raise %DBConnection.OwnershipError{message: "still no owner"}
      end)
    end

    # 5 total attempts (0..4) before the loop gives up on the 5th failure.
    assert Agent.get(counter, & &1) == 5
  end
end

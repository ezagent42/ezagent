defmodule Ezagent.Persistence.TransientRetry do
  @moduledoc """
  Bounded retry wrapper for transient PostgreSQL write failures.

  Feature code should call this helper instead of matching adapter errors
  directly. The helper is intentionally narrow: constraint errors and schema
  drift still raise immediately.
  """

  @retry_max_attempts 5
  @retry_base_ms 10

  @transient_postgres_codes MapSet.new([
                              :deadlock_detected,
                              :lock_not_available,
                              :serialization_failure
                            ])

  @spec with_retry((-> result)) :: result when result: term()
  def with_retry(fun) when is_function(fun, 0), do: do_with_retry(fun, 0)

  defp do_with_retry(fun, attempt) do
    try do
      fun.()
    rescue
      e ->
        if transient?(e) and attempt + 1 < @retry_max_attempts do
          Process.sleep(@retry_base_ms * Bitwise.bsl(1, attempt))
          do_with_retry(fun, attempt + 1)
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp transient?(%Postgrex.Error{postgres: %{code: code}}) do
    MapSet.member?(@transient_postgres_codes, code)
  end

  defp transient?(%DBConnection.ConnectionError{}), do: true

  # Test-only in practice: `OwnershipError` only exists under
  # `Ecto.Adapters.SQL.Sandbox` (`Mix.env() == :test`), raised when a shared-mode
  # owner has already exited and the pool reverted to `:manual` before this
  # attempt. Dead branch in prod. Retrying gives a since-re-established owner (the
  # next `async: false` test's setup, or a delayed shared-mode recovery) a chance
  # to land instead of turning a harness timing race into a hard failure.
  defp transient?(%DBConnection.OwnershipError{}), do: true

  defp transient?(_), do: false
end

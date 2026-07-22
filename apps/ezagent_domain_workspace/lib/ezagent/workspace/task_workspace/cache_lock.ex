defmodule Ezagent.Workspace.TaskWorkspace.CacheLock do
  @moduledoc "Crash-safe node-local serialization for one shared Git cache identity."

  @registry Ezagent.Workspace.TaskWorkspace.CacheLockRegistry
  @default_timeout_ms 5_000

  @doc "Runs a function while the caller owns the node-local cache key."
  @spec with_lock(String.t(), (-> result)) :: result when result: term()
  def with_lock(cache_identity, function),
    do: with_lock(cache_identity, @default_timeout_ms, function)

  @doc "Runs a function after bounded waiting for the node-local cache key."
  @spec with_lock(String.t(), non_neg_integer(), (-> result)) ::
          result | {:error, :cache_lock_timeout}
        when result: term()
  def with_lock(cache_identity, timeout_ms, function)
      when is_binary(cache_identity) and is_integer(timeout_ms) and timeout_ms >= 0 and
             is_function(function, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    acquire(cache_identity, deadline, function)
  end

  defp acquire(cache_identity, deadline, function) do
    case Registry.register(@registry, cache_identity, nil) do
      {:ok, _owner} ->
        try do
          function.()
        after
          Registry.unregister(@registry, cache_identity)
        end

      {:error, {:already_registered, _owner}} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(5, remaining))
          acquire(cache_identity, deadline, function)
        else
          {:error, :cache_lock_timeout}
        end
    end
  end
end

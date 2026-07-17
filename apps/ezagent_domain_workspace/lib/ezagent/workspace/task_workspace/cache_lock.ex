defmodule Ezagent.Workspace.TaskWorkspace.CacheLock do
  @moduledoc "Crash-safe node-local serialization for one shared Git cache identity."

  @registry Ezagent.Workspace.TaskWorkspace.CacheLockRegistry

  @doc "Runs a function while the caller owns the node-local cache key."
  @spec with_lock(String.t(), (() -> result)) :: result when result: term()
  def with_lock(cache_identity, function)
      when is_binary(cache_identity) and is_function(function, 0) do
    case Registry.register(@registry, cache_identity, nil) do
      {:ok, _owner} ->
        try do
          function.()
        after
          Registry.unregister(@registry, cache_identity)
        end

      {:error, {:already_registered, _owner}} ->
        Process.sleep(5)
        with_lock(cache_identity, function)
    end
  end
end

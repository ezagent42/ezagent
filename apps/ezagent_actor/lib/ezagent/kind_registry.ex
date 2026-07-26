defmodule Ezagent.KindRegistry do
  @moduledoc """
  KindRegistry — URI → pid index for Kind instances.

  Thin wrapper over stdlib `Registry` (started in
  `EzagentActor.Application` children as `{Registry, keys: :unique, name:
  Ezagent.KindRegistry}`). Borrowed pattern from the old esr
  `Ezagent.Entity.Registry` shape (SPEC §当前 esr 状态对照 borrow #1) but
  with `put_new` as the **only** registration path so the
  "unique-key" invariant (#4) is enforceable by grep.

  Index scope (per ARCHITECTURE.md §6 line 1031): **only** URI → pid.
  Secondary indices (e.g. by name, by role) belong in
  `Ezagent.RoutingRegistry` and are out of scope for Phase 1.

  ## Why no bare `Registry.register`

  The "put_new for unique-key" invariant (#4) is enforced by grep:
  `grep -rn "Registry.register" apps/ezagent_core --include='*.ex' |
  grep -v put_new` should be empty. If a future contributor reaches
  for `Registry.register/3` they bypass our duplicate-key crash —
  the registration could silently overwrite a prior live instance.
  `put_new/2` always goes through `Registry.register/3` with explicit
  conflict handling so we crash-detect duplicates.
  """

  @registry __MODULE__

  @doc """
  Register the calling process as the owner of `uri` in the registry.

  Returns `:ok` on success. Returns `{:error, {:already_registered,
  existing_pid}}` if some other process already holds this URI —
  caller should crash (let-it-crash) so the duplicate spawn doesn't
  silently succeed.

  Per Decision #66 this is the *only* registration entrypoint. Phase 1
  step 2 calls this from `Ezagent.Kind.Server.init/1`.
  """
  @spec put_new(URI.t() | String.t(), pid()) ::
          :ok | {:error, {:already_registered, pid()}}
  def put_new(uri, pid \\ self()) do
    key = key(uri)

    case Registry.register(@registry, key, pid) do
      {:ok, _own_pid} ->
        :ok

      {:error, {:already_registered, other_pid}} ->
        {:error, {:already_registered, other_pid}}
    end
  end

  @doc """
  Look up the pid registered for a URI.

  Returns `{:ok, pid}` or `:error` (no match).
  """
  @spec lookup(URI.t() | String.t()) :: {:ok, pid()} | :error
  def lookup(uri) do
    case Registry.lookup(@registry, key(uri)) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  List all `{uri_string, pid}` currently registered.

  O(n) over the registry — for admin/debug, not hot-path use.
  """
  @spec list_all() :: [{String.t(), pid()}]
  def list_all do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  defp key(%URI{} = uri), do: URI.to_string(uri)
  defp key(uri) when is_binary(uri), do: uri
end

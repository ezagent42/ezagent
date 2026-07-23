defmodule Ezagent.Cap.RuntimeView do
  @moduledoc """
  Process-dictionary compartment carrying the CURRENT in-process dispatch's
  `{kind_module, slice_state}`.

  This is the IN-PROCESS twin of the cross-process `:ezagent_runtime_view`
  `GenServer.call` that `Ezagent.Cap.action_context/3` uses for a non-self target.
  A SELF-target capability issuance (`pid == self()`) cannot call its own Kind
  process to read the live view — that deadlocks — which is exactly why the
  self-target branch historically fell back to the type-level global
  `Ezagent.BehaviorRegistry`. That approximation cannot express "THIS instance
  hosts behavior X" (the registry is keyed by `{kind_module, action}`, one static
  table per Kind TYPE), so a flavor-only, per-instance action fails to resolve.

  This compartment closes that gap: `Ezagent.Kind.Runtime.do_handle_dispatch/4`
  installs the current instance's `{kind_module, slice_state}` for the duration of
  a single dispatch — the SAME scope in which the framework-private
  `Ezagent.Cap.Authority` compartment (`with_current/2`) is held — and the
  self-target branch of `Ezagent.Cap.action_context/3` reads it to resolve the
  target action against the instance's OWN effective behavior set
  (`Ezagent.Kind.BehaviorSet.resolve_action/3`).

  ## Why this is SEPARATE from `Ezagent.Cap.Authority`

  `Ezagent.Cap.Authority` is signing KEY MATERIAL with `@enforce_keys`; the
  mutable per-instance slice state does not belong on that struct. The value held
  here is NOT secret — it is the instance's own slice map, already an
  authorization INPUT — and it never authorizes anything on its own: the
  self-target branch still gates on `Ezagent.Cap.Authority.current_target?/1`, and
  the resolved `{kind_module, behavior_module}` still feeds the UNCHANGED signed-cap
  verifier.

  ## Nesting safety

  `with_current/3` saves and restores any outer value with `try/after`, so a
  nested / re-entrant dispatch in the same process restores the caller's view on
  exit. A leaked entry would let a LATER self-target resolution read a STALE
  instance's `slice_state` — a correctness AND security hazard — so the
  save/restore is load-bearing.
  """

  @key {__MODULE__, :current}

  @doc """
  Run `fun` with `{kind_module, slice_state}` installed as the current in-process
  runtime view, restoring any previous value on exit (nesting-safe).
  """
  @spec with_current(module(), %{atom() => map()}, (-> result)) :: result
        when result: term()
  def with_current(kind_module, slice_state, fun)
      when is_atom(kind_module) and is_map(slice_state) and is_function(fun, 0) do
    previous = Process.put(@key, {kind_module, slice_state})

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @doc """
  The current in-process runtime view, or `:error` when none is installed
  (framework/genesis paths outside a dispatch).
  """
  @spec current() :: {:ok, {module(), %{atom() => map()}}} | :error
  def current do
    case Process.get(@key) do
      {kind_module, slice_state} when is_atom(kind_module) and is_map(slice_state) ->
        {:ok, {kind_module, slice_state}}

      nil ->
        :error
    end
  end
end

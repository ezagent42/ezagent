defmodule Ezagent.Kind.Introspection do
  @moduledoc false

  @doc """
  Is the given module a new-style Kind (declared via `use
  Ezagent.Kind`)?
  """
  @spec new_style?(module()) :: boolean()
  def new_style?(mod) when is_atom(mod) do
    function_exported?(mod, :__kind__?, 0) and apply(mod, :__kind__?, [])
  end

  @doc """
  Returns the SPEC §3 pattern for this Kind, or `nil` if the
  Kind doesn't use the new contract.
  """
  @spec pattern_of(module()) :: Ezagent.Kind.pattern() | nil
  def pattern_of(mod) when is_atom(mod) do
    if function_exported?(mod, :__pattern__, 0) do
      apply(mod, :__pattern__, [])
    end
  end

  # ---------------------------------------------------------------------
  # Phase 4 Item 1 (2026-05-28) — unified attach-metadata accessors.
  #
  # Background: a Kind module may declare its Behaviors via TWO paths:
  #
  #   - The legacy `@behaviour Ezagent.Kind` + explicit `def behaviors/0`
  #     callback (every Kind in `apps/ezagent_domain_*` uses this).
  #   - The new `use Ezagent.Kind, pattern: ...` + `attach Behavior, ...`
  #     DSL, which auto-generates `__attached_behaviors__/0`.
  #
  # Plugin Kinds (CurlAgent, PyAgent) use BOTH simultaneously — they
  # `use Ezagent.Kind` AND keep `def behaviors/0` for explicit clarity.
  # Pre-PR-464 (Phase 3) the two could silently drift: Kind.Server +
  # Kind.Runtime called `kind.behaviors()` (explicit), the registry
  # introspection called `__attached__()` (macro). codex r3 on PR #458
  # flagged the dual-source-of-truth.
  #
  # `behaviors_of/1` is the canonical accessor for runtime consumers.
  # When BOTH paths are exported AND disagree, we PREFER the macro
  # metadata (`__attached_behaviors__/0` — what the compile-time DSL
  # actually produced + verified for collisions) and log a warning so
  # the drift surfaces in dev logs without crashing the live system.
  # ---------------------------------------------------------------------

  @doc """
  Return the list of Behaviors attached to this Kind.

  Prefers the macro-generated `__attached_behaviors__/0` (produced by
  `use Ezagent.Kind` + `attach`) when available. Falls back to the
  explicit `behaviors/0` callback for Kinds that don't yet use the
  DSL. When BOTH are present AND their lists differ, the macro list
  wins and a `Logger.warning/1` records the drift so the author sees
  it in dev logs.
  """
  @spec behaviors_of(module()) :: [module()]
  def behaviors_of(kind_module) when is_atom(kind_module) do
    has_attach? = function_exported?(kind_module, :__attached_behaviors__, 0)
    has_callback? = function_exported?(kind_module, :behaviors, 0)

    cond do
      has_attach? and has_callback? ->
        attach_list = apply(kind_module, :__attached_behaviors__, [])
        callback_list = apply(kind_module, :behaviors, [])

        if MapSet.new(attach_list) != MapSet.new(callback_list) do
          require Logger

          Logger.warning(
            "Ezagent.Kind.behaviors_of/1: " <>
              "#{inspect(kind_module)} declares Behaviors via BOTH `use Ezagent.Kind` + " <>
              "`attach` (#{inspect(attach_list)}) AND `def behaviors/0` " <>
              "(#{inspect(callback_list)}); the two sets differ. Preferring the " <>
              "attach-metadata list (compile-time verified for action collisions). " <>
              "Reconcile by removing `def behaviors/0` or updating the `attach` block."
          )
        end

        attach_list

      has_attach? ->
        apply(kind_module, :__attached_behaviors__, [])

      has_callback? ->
        apply(kind_module, :behaviors, [])

      true ->
        []
    end
  end

  @doc """
  Return the persistence strategy declared by this Kind.

  Today every Kind exports `def persistence/0` explicitly (the
  `use Ezagent.Kind` macro does not inject it — there's no sensible
  default). This accessor exists for symmetry with `behaviors_of/1`
  so runtime call sites read a single uniform API; a future PR that
  teaches the macro to inject persistence via `use Ezagent.Kind,
  persistence: ...` won't need to touch every consumer.
  """
  @spec persistence_of(module()) :: Ezagent.Kind.persistence_policy()
  def persistence_of(kind_module) when is_atom(kind_module) do
    kind_module.persistence()
  end
end

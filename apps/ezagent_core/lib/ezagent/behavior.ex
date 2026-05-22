defmodule Ezagent.Behavior do
  @moduledoc """
  Behavior — contract for a piece of action-handling logic.

  A Behavior is a small module that:
  - declares what actions it implements (`actions/0`)
  - declares the slice of Kind state it owns (`state_slice/0`)
  - initialises that slice (`init_slice/1`)
  - executes an action against the slice (`invoke/4`)
  - exposes its `@interface` for adapter generation and arg validation
    (`interface/0`)

  Phase 1's only Behavior is `Ezagent.Behavior.Echo` (in `ezagent_plugin_echo`,
  arrives at step 4); the contract is defined here in `ezagent_core` so any
  plugin can implement it.

  ## Why no macros

  Per Decision #84 / DECISIONS P1-D2, Phase 1 picks the
  `@behaviour Ezagent.Behavior` + callback pattern over a `use Ezagent.Behavior`
  macro. The trade-off is identical to the Kind one (compile-time vs
  runtime isolation); same rationale applies (single Behavior in Phase 1,
  re-evaluate Phase 2+).
  """

  @type action :: atom()
  @type slice :: map()
  @type args :: map()
  @type ctx :: map()
  @type result :: term()

  @type invoke_return ::
          {:ok, new_slice :: slice()}
          | {:ok, new_slice :: slice(), result :: result()}
          | {:ok, new_slice :: slice(), stream :: Enumerable.t()}
          | {:error, reason :: term()}

  @doc "List of action atoms this Behavior implements."
  @callback actions() :: [action()]

  @doc """
  Atom key under which this Behavior's slice lives in the Kind's state
  map. Convention: `:behavior_name` (e.g. `:echo`, `:chat`). Per
  DECISIONS impl-time §`Ezagent.Kind.Server` state shape — atoms not
  modules.
  """
  @callback state_slice() :: atom()

  @doc """
  Build the initial slice from boot-time args. Called by
  `Ezagent.Kind.Server.init/1` for each declared Behavior.
  """
  @callback init_slice(args :: args()) :: slice()

  @doc """
  Execute an action against the slice.

  Returns one of:
  - `{:ok, new_slice}` — silent success (cast)
  - `{:ok, new_slice, result}` — success with return value (call)
  - `{:ok, new_slice, stream}` — streaming return (call_stream)
  - `{:error, reason}` — action failed
  """
  @callback invoke(
              action :: action(),
              slice :: slice(),
              args :: args(),
              ctx :: ctx()
            ) :: invoke_return()

  @doc """
  Adapter-generation + arg-validation source.

  Shape: `%{<action_atom> => %{description: <String.t()>, args: <type_spec>,
  returns: <type_spec>, modes: [<mode>]}}`. Used by
  `Ezagent.InterfaceValidator.validate/2` at dispatch time.

  `description:` is OPTIONAL (V1 UI SPEC §0) — a one-line human-readable
  summary of what the action does, surfaced by the CLI `tree_builder` and
  CmdK. When present it MUST be a binary; `Ezagent.InterfaceValidator.validate_action/1`
  enforces this. Behaviors SHOULD supply it so consumers rarely fall back
  to generic text.
  """
  @callback interface() :: %{
              atom() => %{
                optional(:description) => String.t(),
                args: map(),
                returns: map(),
                modes: [atom()]
              }
            }
end

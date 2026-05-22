defmodule Ezagent.Orchestrator.SlotNames do
  @moduledoc """
  MEDIUM-3 (Phase 7 hardening round 3) — the up-front slot-name
  uniqueness preflight.

  ## The problem

  A worker's live instance URI is derived deterministically from its
  generated instance name (`Ezagent.Entity.Agent.session_instance_name/3`)
  — `entity://agent/<workspace>/<flavor>_<instance_name>`. The instance
  name folds the slot name + a hash + the session discriminator + an
  optional generation counter.

  Round 2 made the encoded slot component INJECTIVE by appending a hash
  of the original slot name. But:

  - the hash was only 8 hex chars (a 32-bit domain) — round 3 widens it
    (`Ezagent.Entity.Agent` `@slot_hash_hex_width`); AND
  - the Generator + `update_agent_template` spawned slot-by-slot, so two
    slots that nonetheless produced the SAME instance name (e.g. an
    accidental hash collision, or — degenerately — two literally-equal
    slot names) were only discovered as a `{:already_started, _}` /
    silent-overwrite at spawn time, MID-WAY through a multi-slot spawn.

  ## The fix — preflight the whole candidate set before any spawn

  `preflight/2` computes EVERY candidate instance name (hence worker
  URI) for the operation up front and REJECTS it if any two collide —
  BEFORE a single `template.instantiate` dispatch. Uniqueness is then
  GUARANTEED, not probabilistic.

  Two call sites:

  - **Generator** (`Ezagent.Entity.Session.spawn_from_template/2`) —
    every agent slot at generation 0, plus the orchestrator's own
    instance name, sharing one session discriminator. A collision →
    the Generator fails before spawning anything.
  - **`update_agent_template`** (`Ezagent.Orchestrator.Tools`) — the
    swapped slot at its bumped generation, plus every OTHER live slot at
    its current generation. A collision → the swap is rejected before
    the replacement worker spawns.

  The preflight is a PURE function — it computes names, it does not
  spawn, dispatch, or touch any registry.
  """

  alias Ezagent.Entity.Agent

  @typedoc """
  One slot's `{slot_name, generation}` — the two inputs (besides the
  shared session discriminator) that determine its instance name.
  """
  @type slot_spec :: {slot_name :: String.t(), generation :: non_neg_integer()}

  @doc """
  Compute the candidate instance name for every `slot_spec` against the
  shared `discriminator` and assert they are all DISTINCT.

  Returns `:ok` when every generated instance name is unique, or
  `{:error, {:duplicate_instance_names, details}}` where `details` is a
  list of `{instance_name, [slot_name, ...]}` — the colliding instance
  name and the slot names that produced it.

  An empty slot list is vacuously `:ok`.
  """
  @spec preflight([slot_spec()], String.t()) ::
          :ok | {:error, {:duplicate_instance_names, [{String.t(), [String.t()]}]}}
  def preflight(slot_specs, discriminator)
      when is_list(slot_specs) and is_binary(discriminator) do
    collisions =
      slot_specs
      |> Enum.group_by(
        fn {slot_name, generation} ->
          Agent.session_instance_name(to_string(slot_name), discriminator, generation)
        end,
        fn {slot_name, _generation} -> to_string(slot_name) end
      )
      |> Enum.filter(fn {_instance_name, slot_names} -> length(slot_names) > 1 end)

    case collisions do
      [] -> :ok
      details -> {:error, {:duplicate_instance_names, details}}
    end
  end
end

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

  `preflight/2` is a PURE function — it computes names, it does not
  spawn, dispatch, or touch any registry.

  ## MEDIUM-3 (round 4) — also reject a candidate already LIVE as an
  ## orphan

  `preflight/2` only groups the candidate instance names against EACH
  OTHER — it never sees a candidate URI that is ALREADY LIVE in
  `Ezagent.KindRegistry` but not in the candidate set. An orphaned
  generation worker left by a prior failed cleanup → a retry generates
  the same name → `preflight/2` passes → `template.instantiate` hits the
  plugin's idempotency (`{:already_started, _}`) and the swap silently
  ADOPTS the stale worker.

  `preflight_live_worker_uris/1` closes that gap: given the FULL
  candidate worker URIs (workspace + flavor + name), it rejects the
  operation if any candidate URI is already registered in `KindRegistry`
  UNLESS that URI is the expected current worker for the slot (so a
  same-URI degenerate is not a false positive). Unlike `preflight/2`
  this DOES read `KindRegistry` — it is the live-orphan check.
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

  @typedoc """
  One candidate's `{candidate_worker_uri, expected_current_uri}`.

  `candidate_worker_uri` is the FULL worker URI the operation is about
  to spawn (`entity://agent/<workspace>/<flavor>_<instance_name>`).
  `expected_current_uri` is the slot's current live worker URI when the
  candidate may legitimately already exist (e.g. a degenerate
  same-generation swap), or `nil` when the candidate must be brand new.
  """
  @type live_candidate :: {URI.t(), URI.t() | nil}

  @doc """
  MEDIUM-3 (round 4) — reject any candidate worker URI that is ALREADY
  LIVE in `Ezagent.KindRegistry` as an orphan.

  For each `{candidate_uri, expected_uri}`: if `candidate_uri` is
  registered in `KindRegistry` AND it is not `expected_uri`, the
  candidate names a worker that already exists but is NOT the one this
  operation expects — an orphan from a prior failed cleanup. A retry
  that reuses that name would `template.instantiate` into the live
  orphan (plugin idempotency) and silently adopt a stale worker.

  Returns `:ok` when every candidate is either absent from
  `KindRegistry` or equals its `expected_uri`, otherwise
  `{:error, {:candidate_uri_already_live, [URI.t(), ...]}}` listing the
  offending candidate URIs.

  An empty candidate list is vacuously `:ok`.
  """
  @spec preflight_live_worker_uris([live_candidate()]) ::
          :ok | {:error, {:candidate_uri_already_live, [URI.t()]}}
  def preflight_live_worker_uris(candidates) when is_list(candidates) do
    orphans =
      candidates
      |> Enum.filter(fn {%URI{} = candidate_uri, expected_uri} ->
        case Ezagent.KindRegistry.lookup(candidate_uri) do
          {:ok, _pid} -> not same_uri?(candidate_uri, expected_uri)
          :error -> false
        end
      end)
      |> Enum.map(fn {candidate_uri, _expected} -> candidate_uri end)

    case orphans do
      [] -> :ok
      _ -> {:error, {:candidate_uri_already_live, orphans}}
    end
  end

  defp same_uri?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp same_uri?(_a, nil), do: false
end

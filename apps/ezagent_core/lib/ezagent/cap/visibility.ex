defmodule Ezagent.Cap.Visibility do
  @moduledoc """
  Cap-derived visibility helpers (URI-share unification, A2).

  The one place that answers "what can I see, from the caps I hold" — the
  **forward** derivation (holder → target instances). Generalizes the per-plugin
  "derive visible targets from `caller_caps`" pattern (kanban's private board
  derivation, workspace / session visibility) into a reusable, plugin-agnostic
  helper so each biz stops re-deriving it.

  It only ENUMERATES the visible target set — the authorization chokepoint stays
  `Ezagent.Cap.authorize/3`; visibility is a superset convenience, never a grant.
  But it IS current-generation aware (H3): a cap whose signing generation is no
  longer the target's active one (a generation-bump revocation) is excluded, so
  forward visibility matches the reverse `grantees_of/2` index and the
  dispatch-time current-gen check — a revoked cap is never surfaced forward while
  hidden in reverse. This costs one authority read per distinct target.

  (The **reverse** direction — "who holds caps toward this target",
  `grantees_of/2` — is a durable derived index maintained at the cap-store
  chokepoint; it lands in a sibling change, A2-2.)
  """

  alias Ezagent.Capability
  alias Ezagent.Ecto.KindCapAuthority

  @doc """
  The concrete target instances a `caps` set grants CURRENT access toward for
  `behavior`.

  Returns the de-duped (by stable key) `%URI{}` target instances of caps whose
  `behavior` matches AND whose signing generation is still the target's active
  one (H3). Wildcard / non-`%URI{}` instances (`:any`) and revoked (stale-
  generation) or unsigned caps are excluded. Accepts a list or a `MapSet`.
  """
  @spec caps_toward(Enumerable.t(), module()) :: [URI.t()]
  def caps_toward(caps, behavior) when is_atom(behavior) do
    caps
    |> Enum.filter(&match?(%Capability{behavior: ^behavior, instance: %URI{}}, &1))
    |> Enum.filter(&current_generation?/1)
    |> Enum.map(fn %Capability{instance: instance} -> Ezagent.URI.instance(instance) end)
    |> Enum.uniq_by(&Ezagent.URI.stable_key/1)
  end

  # H3: the same `key_id == active` currency test the dispatch cap verifier does
  # (without re-verifying the signature — visibility is a superset convenience,
  # not the authorization chokepoint). A generation-bump revocation changes the
  # target's active `key_id`, so a stale-generation cap drops out of forward
  # visibility exactly as it drops out of the reverse `grantees_of` index.
  # Unsigned/legacy caps (no `key_id`) are never "current".
  defp current_generation?(%Capability{instance: instance, key_id: key_id})
       when is_binary(key_id) do
    active_key_id(Ezagent.URI.stable_key(Ezagent.URI.instance(instance))) == key_id
  end

  defp current_generation?(%Capability{}), do: false

  defp active_key_id(target_key) do
    case KindCapAuthority.active(target_key) do
      %{key_id: key_id} -> key_id
      _ -> nil
    end
  end
end

defmodule Ezagent.Cap.Visibility do
  @moduledoc """
  Cap-derived visibility helpers (URI-share unification, A2).

  The one place that answers "what can I see, from the caps I hold" — the
  **forward** derivation (holder → target instances). Generalizes the per-plugin
  "derive visible targets from `caller_caps`" pattern (kanban's private board
  derivation, workspace / session visibility) into a reusable, plugin-agnostic
  helper so each biz stops re-deriving it.

  Pure over `%Ezagent.Capability{}` structs — no store, no authorization: this
  only ENUMERATES the visible target set. The authorization chokepoint stays
  `Ezagent.Cap.authorize/3`; visibility is a superset convenience, never a grant.

  (The **reverse** direction — "who holds caps toward this target",
  `grantees_of/2` — is a durable derived index maintained at the cap-store
  chokepoint; it lands in a sibling change, A2-2.)
  """

  alias Ezagent.Capability

  @doc """
  The concrete target instances a `caps` set grants access toward for `behavior`.

  Returns the de-duped (by stable key) `%URI{}` target instances of caps whose
  `behavior` matches; wildcard / non-`%URI{}` instances (`:any`) are excluded
  (they name no concrete target). Accepts a list or a `MapSet`.
  """
  @spec caps_toward(Enumerable.t(), module()) :: [URI.t()]
  def caps_toward(caps, behavior) when is_atom(behavior) do
    caps
    |> Enum.filter(&match?(%Capability{behavior: ^behavior, instance: %URI{}}, &1))
    |> Enum.map(fn %Capability{instance: instance} -> Ezagent.URI.instance(instance) end)
    |> Enum.uniq_by(&Ezagent.URI.stable_key/1)
  end
end

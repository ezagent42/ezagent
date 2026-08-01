defmodule Ezagent.World.PresenterCaps do
  @moduledoc """
  Single source for capabilities carried by World-originated dispatches.

  `load/1` re-derives the presenter's caps FRESH from the live/durable Identity
  store on every action — it is exactly `IdentityCaps.load(presenter)`, full stop.
  LiveView's `current_caps` assign is a mount-time bootstrap snapshot and is NO
  LONGER trusted: merging it let a bootstrap-only authority artifact survive a
  mid-session grant/revoke/demotion (a demoted admin kept publish/admin rights
  until re-login — docs/futures/todo.md 2026-07-22). Fresh derivation closes that
  staleness on the very next action.

  The one caller that legitimately carries EPHEMERAL caps minted at request time
  (a JIT-issued capability that is never written to the principal's durable
  Identity slice — e.g. `EzagentWeb.Socialware.KanbanPublishedReadAdapter`, whose
  cap comes from `Ezagent.Cap.issue/3`, not a durable grant) uses the explicit
  narrow `load_with_ephemeral/2` path. That path admits ONLY caps carried in the
  `#{inspect(__MODULE__)}.EphemeralCaps` TAG — an arbitrary or stale
  `%Ezagent.Capability{}` cannot be smuggled onto a presenter's cap set, so there
  is no reservoir for a future stale-cap injection. No other path may resurrect a
  mount snapshot.
  """

  alias Ezagent.Capability

  defmodule EphemeralCaps do
    @moduledoc """
    Tagged container for request-time JIT capabilities minted per request (via
    `Ezagent.Cap.issue/3`) and NEVER persisted to the principal's durable Identity
    slice — e.g. the kanban published-read share path.

    `Ezagent.World.PresenterCaps.load_with_ephemeral/2` admits ONLY caps carried
    in this wrapper: a caller must EXPLICITLY opt into the ephemeral union by
    constructing the tag, so a bare enumerable or an arbitrary/stale
    `%Ezagent.Capability{}` is rejected rather than silently trusted.
    """
    @enforce_keys [:caps]
    defstruct [:caps]
    @type t :: %__MODULE__{caps: Enumerable.t()}
  end

  @doc """
  Load the presenter's current caps FRESH from the Identity store (§2.2). Never
  merges the mount-time `current_caps` snapshot — see the moduledoc.
  """
  @spec load(Phoenix.LiveView.Socket.t() | map()) :: MapSet.t(Capability.t())
  def load(%{assigns: assigns}) when is_map(assigns), do: load(assigns)

  def load(assigns) when is_map(assigns) do
    assigns
    |> fresh_caps()
    |> MapSet.new()
  end

  @doc """
  Fresh presenter caps UNIONED with an explicit, TAGGED set of ephemeral caps
  (§C1 carve-out). Admits ONLY an `EphemeralCaps` wrapper — a bare enumerable or
  an arbitrary `%Capability{}` is REJECTED (function-clause) so no path other
  than an explicit JIT-cap opt-in can add caps the fresh load would not surface.
  Fresh (durable) caps win over ephemeral caps of the same identity.
  """
  @spec load_with_ephemeral(Phoenix.LiveView.Socket.t() | map(), EphemeralCaps.t()) ::
          MapSet.t(Capability.t())
  def load_with_ephemeral(%{assigns: assigns}, %EphemeralCaps{} = ephemeral) when is_map(assigns),
    do: load_with_ephemeral(assigns, ephemeral)

  def load_with_ephemeral(assigns, %EphemeralCaps{caps: caps}) when is_map(assigns) do
    merge(caps, fresh_caps(assigns))
  end

  defp fresh_caps(assigns) do
    case Map.get(assigns, :current_entity_uri) do
      %URI{} = presenter -> Ezagent.IdentityCaps.load(presenter)
      _ -> []
    end
  end

  @doc false
  @spec context(Phoenix.LiveView.Socket.t() | map()) :: map()
  def context(%{assigns: assigns} = socket) when is_map(assigns) do
    presenter = Map.fetch!(assigns, :current_entity_uri)

    %{
      caller: presenter,
      authenticated_principal: presenter,
      caps: load(socket)
    }
  end

  # Set-union keyed by capability identity; `current` (fresh/durable) entries win
  # over same-identity `ephemeral` entries. Private — the only public ephemeral
  # entry is `load_with_ephemeral/2`, which is tag-gated.
  defp merge(ephemeral, current) do
    ephemeral
    |> Enum.concat(current)
    |> Enum.reduce(%{}, fn
      %Capability{} = cap, acc -> Map.put(acc, Capability.identity_key(cap), cap)
      _other, acc -> acc
    end)
    |> Map.values()
    |> MapSet.new()
  end
end

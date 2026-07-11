defmodule Ezagent.Session.ExternalDelivery do
  @moduledoc """
  External-delivery topic builder for the session domain.

  The canonical builder for the external-feed PubSub topic. The exact string
  (`"socialware:external:" <> URI.to_string(session_uri)`) is a WIRE CONVENTION
  consumed by the external SPA's web channel — do NOT change it without changing
  the channel + socket in lockstep.

  Relocated here (P5-1a) alongside `Settlement` + `DeliveryOutbox` so the
  external-delivery substrate has no upward dependency on the socialware
  `ExternalFeed`. `Ezagent.Socialware.ExternalFeed.topic/1` now delegates here.
  """

  @doc """
  The canonical external-feed PubSub topic for `session_uri`.

  Returns `"socialware:external:" <> URI.to_string(session_uri)`. This exact
  string is a WIRE CONVENTION shared with the external SPA's web channel — treat
  it as a contract and change the channel + socket in lockstep if it ever moves.
  """
  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = session_uri), do: "socialware:external:" <> URI.to_string(session_uri)
end

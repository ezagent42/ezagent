defmodule Ezagent.Session.CustomerDelivery do
  @moduledoc """
  Customer-delivery topic builder for the session domain.

  The canonical builder for the customer-feed PubSub topic. The exact string
  (`"socialware:customer:" <> URI.to_string(session_uri)`) is a WIRE CONVENTION
  consumed by the customer SPA's web channel — do NOT change it without changing
  the channel + socket in lockstep.

  Relocated here (P5-1a) alongside `Settlement` + `CustomerOutbox` so the
  customer-delivery substrate has no upward dependency on the socialware
  `CustomerFeed`. `Ezagent.Socialware.CustomerFeed.topic/1` now delegates here.
  """

  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = session_uri), do: "socialware:customer:" <> URI.to_string(session_uri)
end

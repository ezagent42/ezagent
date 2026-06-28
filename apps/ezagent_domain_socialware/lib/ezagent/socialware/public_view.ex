defmodule Ezagent.Socialware.PublicView do
  @moduledoc """
  Anonymous web-access gate for installed socialwares.

  P4 split the old template boolean into a real install relation plus the
  socialware definition's `visibility_policy.web_anon_access` field. This module
  remains as a compatibility facade for older callers; new code should call
  `web_anon_access?/1`.
  """

  @doc """
  Whether any installed socialware on `session_uri` permits anonymous web access.

  Fail-closed: missing install records, unreadable definitions, and non-session
  URIs all return `false`.
  """
  @spec web_anon_access?(URI.t()) :: boolean()
  def web_anon_access?(%URI{scheme: "session"} = session_uri),
    do: Ezagent.Socialware.Installation.web_anon_access?(session_uri)

  def web_anon_access?(_), do: false
end

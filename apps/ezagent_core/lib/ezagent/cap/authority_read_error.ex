defmodule Ezagent.Cap.AuthorityReadError do
  @moduledoc """
  Raised when a capability's TARGET-authority row cannot be read due to a
  TRANSIENT store failure (timeout / exit / pool starvation) — as distinguished
  from a genuine stale/absent authority, which is a normal `{:ok, false}`
  verify result.

  Callers that re-verify a cap's target generation MUST fail LOUD on this
  rather than convert it into a capability denial: a store blip must never
  masquerade as "unauthorized". This is the silent-denial class fixed by #1346
  and enforced by the `Ezagent.Cap.HoldsCap` fail-loud contract — surfaced by
  the CHECKED target-authority verifier in `Ezagent.Cap.Authority` via its
  `{:error, :authority_read_failed}` result.
  """

  defexception [:target, :grantee, :message]

  @impl true
  def exception(opts) do
    target = Keyword.get(opts, :target)
    grantee = Keyword.get(opts, :grantee)

    message =
      Keyword.get(opts, :message) ||
        "transient authority-store read failed verifying cap target " <>
          "#{inspect(target && URI.to_string(target))} for grantee " <>
          "#{inspect(grantee && URI.to_string(grantee))} — refusing to convert to a denial (#1346)"

    %__MODULE__{target: target, grantee: grantee, message: message}
  end
end

defmodule Ezagent.Socialware.Share do
  @moduledoc """
  URI-agnostic **share** orchestration (A1) — the claim edge.

  "Sharing a URI" = delegating a cap toward it. A share link is a signed BEARER
  token (`Ezagent.Cap.ShareToken`, core) naming a `target` URI + the `behavior`
  (ActionSet) and `actions` it grants; the clicker is unknown at share time.
  **Claiming** binds it: the authenticated clicker becomes the grantee, and a
  grantee-bound cap is minted toward the target via the single mint chokepoint
  `CompositionCaps.mint_cap/4` (granter ≡ the target's `data_owner`, #154). This
  is cap-as-truth `甲`: bearer → mint.

  This module lives in `ezagent_domain_session` — the layer that owns
  `CompositionCaps` (mint). It is URI-agnostic: `target` may be any URI whose
  behavior has a resolvable `data_owner` (kanban board = `entity://…/agent/…`,
  and any future shareable data-host). Zero plugin literal — `behavior`/`actions`
  ride in the (signed) token.

  Authorization is on the **mint side**: the sharer must have access to `target`
  to sign a link (the share-link producer authorizes before calling
  `ShareToken.mint_link!/4`). The claim path here does not re-authorize the
  clicker — the token IS the share-time credential; it only mints the cap the
  link already grants.
  """

  alias Ezagent.Cap.ShareToken
  alias Ezagent.Socialware.CompositionCaps

  @type claim_result :: %{target: URI.t(), grantee: URI.t()}

  @doc """
  Claim a share link as `clicker`: verify the bearer token, then mint a
  grantee-bound cap toward its target for `clicker`.

  Returns `{:ok, %{target, grantee}}`, or `{:error, reason}`:

    * `{:error, :expired}` / a `Phoenix.Token` reason — bad/expired/tampered link;
    * a `CompositionCaps.mint_cap/4` error (e.g. `{:operate_target_ownerless, …}`)
      — the target has no resolvable owner to grant from (fail-closed).
  """
  @spec claim(String.t(), URI.t()) :: {:ok, claim_result()} | {:error, term()}
  def claim(token, %URI{} = clicker) when is_binary(token) do
    with {:ok, %{target: target, behavior: behavior, actions: actions}} <-
           ShareToken.verify_link(token),
         {:ok, _caps} <- CompositionCaps.mint_cap(clicker, target, behavior, actions) do
      {:ok, %{target: target, grantee: clicker}}
    end
  end
end

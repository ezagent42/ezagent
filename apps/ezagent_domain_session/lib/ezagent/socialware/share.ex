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

  Authorization is bound to the **issuer** (the link author) and verified at
  BOTH ends: `mint_link/4` refuses to sign unless the issuer is the target's
  data_owner (delegable authority), and `claim/2` re-verifies the token's
  MAC-bound issuer against the target's CURRENT data_owner before minting. So a
  server-signed link can only grant authority its issuer actually held — a
  bearer token is not, by itself, authority (codex M1, Allen D1: granter ≡
  data_owner).
  """

  alias Ezagent.Cap.ShareToken
  alias Ezagent.Socialware.CompositionCaps

  @type claim_result :: %{target: URI.t(), grantee: URI.t()}

  @doc """
  Mint a share link as `issuer` for `target`, granting `behavior`'s `actions`.

  The single sanctioned producer: verifies `issuer` is authorized to delegate on
  `target` (issuer ≡ the target's data_owner) BEFORE signing, so no unauthorized
  link is ever produced. `opts` pass through to `ShareToken.mint_link!/5`
  (e.g. `:ttl_seconds`). Returns `{:ok, token}` or
  `{:error, {:share_issuer_not_data_owner, issuer, owner}}` /
  `{:error, {:share_target_ownerless, target}}`.

  The caller MUST pass the AUTHENTICATED sharer as `issuer` (never a
  client-supplied value) — this function proves the issuer's authority, but
  cannot prove the caller IS the issuer.
  """
  @spec mint_link(URI.t(), URI.t(), module(), [atom()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def mint_link(%URI{} = issuer, %URI{} = target, behavior, actions, opts \\ [])
      when is_atom(behavior) and is_list(actions) do
    with :ok <- assert_issuer_authorized(issuer, target, behavior),
         :ok <- assert_target_conformant(target, behavior, actions) do
      {:ok, ShareToken.mint_link!(issuer, target, behavior, actions, opts)}
    end
  end

  @doc """
  Claim a share link as `clicker`: verify the bearer token, re-verify the
  MAC-bound issuer still holds delegable authority on the target, then mint a
  grantee-bound cap toward the target for `clicker`.

  Returns `{:ok, %{target, grantee}}`, or `{:error, reason}`:

    * `{:error, :expired}` / a `Phoenix.Token` reason — bad/expired/tampered link;
    * `{:error, {:share_issuer_not_data_owner, issuer, owner}}` — the link's
      issuer is no longer (or never was) the target's data_owner (M1 fail-closed:
      re-verified against CURRENT ownership, so a revoked/transferred target
      invalidates outstanding links);
    * `{:error, {:share_target_ownerless, target}}` — no resolvable owner;
    * a `CompositionCaps.mint_cap/4` error (fail-closed mint).
  """
  @spec claim(String.t(), URI.t()) :: {:ok, claim_result()} | {:error, term()}
  def claim(token, %URI{} = clicker) when is_binary(token) do
    with {:ok, %{issuer: issuer, target: target, behavior: behavior, actions: actions}} <-
           ShareToken.verify_link(token),
         :ok <- assert_issuer_authorized(issuer, target, behavior),
         :ok <- assert_target_conformant(target, behavior, actions),
         {:ok, _caps} <- CompositionCaps.mint_cap(clicker, target, behavior, actions) do
      {:ok, %{target: target, grantee: clicker}}
    end
  end

  # M1: the link's issuer must BE the target's current data_owner (Allen D1,
  # granter ≡ data_owner). Fail-closed on any non-concrete owner (`:any` /
  # `:no_owner` / scope-tuple) — a share must name a concrete accountable owner.
  defp assert_issuer_authorized(%URI{} = issuer, %URI{} = target, behavior) do
    case Ezagent.CapabilityRegistry.data_owner_of(behavior, Ezagent.URI.instance(target)) do
      %URI{} = owner ->
        if same_instance?(issuer, owner),
          do: :ok,
          else: {:error, {:share_issuer_not_data_owner, issuer, owner}}

      _ ->
        {:error, {:share_target_ownerless, target}}
    end
  end

  defp same_instance?(a, b) do
    Ezagent.URI.stable_key(Ezagent.URI.instance(a)) ==
      Ezagent.URI.stable_key(Ezagent.URI.instance(b))
  end

  # M2: verify the target actually handles `behavior`'s `actions` before minting,
  # so a link can never grant a behavior the target lacks (a dead cap dispatch
  # would reject anyway — this fails closed earlier). Uses the URI-kind-agnostic
  # `Ezagent.Kind.resolve_action_subject/2` (resolves the handling behavior INSIDE
  # the target actor, for ANY Kind — not hardcoded to agents), so session:// /
  # resource:// targets validate on the same path.
  defp assert_target_conformant(%URI{} = target, behavior, actions) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      # `resolve_action_subject/2` returns `{:ok, {kind_module, behavior_module}}`.
      case Ezagent.Kind.resolve_action_subject(target, action) do
        {:ok, {_kind_module, ^behavior}} ->
          {:cont, :ok}

        {:ok, {_kind_module, other}} ->
          {:halt, {:error, {:share_target_not_conformant, target, behavior, action, other}}}

        {:error, {:unknown_action, _}} ->
          {:halt, {:error, {:share_target_not_conformant, target, behavior, action, :unknown_action}}}

        {:error, reason} ->
          {:halt, {:error, {:share_target_not_live, target, reason}}}
      end
    end)
  end
end

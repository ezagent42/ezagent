defmodule Ezagent.Socialware.Share do
  @moduledoc """
  URI-agnostic **share** orchestration (A1) — the Feishu-style two-layer model.

  Sharing is two decoupled layers:

    * **Permission = caps** — who holds a cap toward a target has access. Direct
      grants + already-claimed collaborators; revoke per-person with
      `Ezagent.Identity.Grant.revoke_cap/3`, list with `grantees_of/2`. This
      module never touches that layer.
    * **Sharing setting = a per-target toggle** (`Ezagent.Socialware.ShareSetting`)
      — whether a share LINK lets people self-acquire a cap, and how open. Only
      the target's `data_owner` can turn it on; that IS the authorization
      (codex M1). Turning it off (`disable/2`) revokes every outstanding link at
      once (codex D3), leaving already-granted caps intact.

  A share link (`Ezagent.Cap.ShareToken`) is a STATELESS pointer at the target —
  it carries no authority. `claim/2` reads the target's current sharing setting
  and mints only if it is enabled, exactly what the setting says. So a
  server-signed link is not authority by itself, and the owner can un-share any
  time by flipping the setting. URI-agnostic: `target` is any URI with a
  resolvable `data_owner`.
  """

  alias Ezagent.Cap.ShareToken
  alias Ezagent.Socialware.{CompositionCaps, ShareSetting}

  @type claim_result :: %{target: URI.t(), grantee: URI.t()}

  @doc """
  Owner turns sharing ON for `target`, declaring a share link grants `behavior`'s
  `actions`. `owner` must be the target's current `data_owner` (verified in
  `ShareSetting.enable/5`). Also verifies the target actually handles the
  behavior/actions (M2 conformance) so a link can't be enabled for a behavior the
  target lacks. `opts`: `:access` (`:read`/`:operate`), `:visibility`
  (`:link_login` / `:link_anon`). Returns `{:ok, setting}` or a fail-closed error.
  """
  @spec enable(URI.t(), URI.t(), module(), [atom()], keyword()) ::
          {:ok, ShareSetting.t()} | {:error, term()}
  def enable(%URI{} = target, %URI{} = owner, behavior, actions, opts \\ [])
      when is_atom(behavior) and is_list(actions) do
    with :ok <- assert_target_conformant(target, behavior, actions) do
      ShareSetting.enable(target, owner, behavior, actions, opts)
    end
  end

  @doc """
  Owner turns sharing OFF for `target` (the revocation): every outstanding link
  stops working; already-granted caps are untouched. Only the current owner may.
  """
  @spec disable(URI.t(), URI.t()) :: {:ok, ShareSetting.t() | nil} | {:error, term()}
  def disable(%URI{} = target, %URI{} = owner), do: ShareSetting.disable(target, owner)

  @doc """
  Mint a share link (stateless pointer) for `target`. It grants nothing unless
  the target's sharing setting is enabled at claim time. `opts` pass through to
  `ShareToken.mint_link!/2` (e.g. `:ttl_seconds`).
  """
  @spec mint_link(URI.t(), keyword()) :: String.t()
  def mint_link(%URI{} = target, opts \\ []), do: ShareToken.mint_link!(target, opts)

  @doc """
  Claim a share link as `clicker`: verify the pointer, read the target's CURRENT
  sharing setting, and — only if sharing is enabled — mint the grantee-bound cap
  the setting declares. Reusable: the same link works for any clicker until it
  expires or the owner disables sharing.

    * `{:error, :expired}` / a `Phoenix.Token` reason — bad/expired/tampered link;
    * `{:error, :share_disabled}` — sharing is off (unset or the owner revoked it);
    * a `CompositionCaps.mint_cap/4` error — fail-closed mint.
  """
  @spec claim(String.t(), URI.t()) :: {:ok, claim_result()} | {:error, term()}
  def claim(token, %URI{} = clicker) when is_binary(token) do
    with {:ok, %{target: target}} <- ShareToken.verify_link(token),
         %ShareSetting{} = setting <- ShareSetting.active(target),
         {:ok, _caps} <-
           CompositionCaps.mint_cap(
             clicker,
             target,
             ShareSetting.behavior_module(setting),
             ShareSetting.actions(setting)
           ) do
      {:ok, %{target: target, grantee: clicker}}
    else
      nil -> {:error, :share_disabled}
      {:error, _} = err -> err
    end
  end

  # M2: verify the target actually handles the behavior's actions before sharing
  # can be enabled — a link can never grant a behavior the target lacks (a dead
  # cap dispatch would reject anyway; this fails closed at enable). Uses the
  # URI-kind-agnostic `Ezagent.Kind.resolve_action_subject/2` (resolves the
  # handling behavior INSIDE the target actor, for ANY Kind), so session:// /
  # resource:// targets validate on the same path.
  defp assert_target_conformant(%URI{} = target, behavior, actions) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
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

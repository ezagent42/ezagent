defmodule Ezagent.Email.Verification do
  @moduledoc """
  Bind-time email verification + alias generation for the email
  ExternalMirror adapter (#88 PR-2 / SPEC §3 / §4.4 / plan D4).

  `bind_session/4` is the email-specific bind WRAPPER (plan D4): it calls
  the GENERIC `Ezagent.ExternalMirror.bind/4` (cap-checked, nonce-gated),
  then on success mints a unique local alias, records the email-owned
  `InboundBinding` row in status `pending_verification`, and sends a
  verification email carrying a one-time confirm LINK (not a reply token —
  a reply would be rejected by the very From-match gate it's trying to
  open; SPEC §4.4). Status flips to `verified` only when the human clicks
  the link (`confirm/1` → the web endpoint).

  Alias generation regenerates-and-retries on the (rare) `local_address`
  unique collision, mirroring the natural-key idempotency pattern in
  `BindingRow.insert/1`.

  ## No web dependency

  This module lives in the email plugin, which must NOT depend on
  `ezagent_web` (plugin isolation). The confirm-link base URL comes from
  app env `:verification_base_url`; the web side owns only the inbound
  confirm GET route (`EzagentWeb.EmailBindingController`), which calls
  `Ezagent.Email.InboundBinding.confirm/1`.
  """

  require Logger

  alias Ezagent.Email.InboundBinding
  alias Ezagent.ExternalMirror.BindingRow

  @adapter_id "email"
  @alias_domain "ezagent.chat"
  @max_alias_retries 5

  @doc """
  Bind a session to a human email `target_id` and start the verification
  handshake. Returns `{:ok, %{binding: bind_result, local_address: alias}}`
  or `{:error, reason}`.

  Steps:
  1. Generic `Ezagent.ExternalMirror.bind/4` (Check 1/2/3 + nonce).
  2. Mint a unique alias, record the `InboundBinding` row
     (`pending_verification`), regenerate-retry on collision.
  3. Send the verification email (best-effort — a send failure leaves the
     binding pending; surfaced via the result + logged).
  """
  @spec bind_session(URI.t(), String.t(), map(), Ezagent.ExternalMirror.caller_ctx()) ::
          {:ok, map()} | {:error, term()}
  def bind_session(%URI{} = session_uri, target_id, opts \\ %{}, ctx)
      when is_binary(target_id) and is_map(opts) and is_map(ctx) do
    with {:ok, bind_result} <-
           Ezagent.ExternalMirror.bind(session_uri, @adapter_id, target_id, opts, ctx),
         {:ok, {row, raw_token}} <- record_inbound_meta(session_uri, target_id) do
      send_verification_email(target_id, raw_token)
      {:ok, %{binding: bind_result, local_address: row.local_address}}
    end
  end

  @doc """
  Mint a unique alias + record the `InboundBinding` row (pending), with
  regenerate-and-retry on a `local_address` collision. Returns
  `{:ok, {row, raw_token}}` | `{:error, reason}`. Public so the alias /
  collision logic is unit-testable without driving the full bind facade
  (which the external_mirror domain already tests).
  """
  @spec record_inbound_meta(URI.t(), String.t()) ::
          {:ok, {InboundBinding.t(), String.t()}} | {:error, term()}
  def record_inbound_meta(%URI{} = session_uri, target_id) when is_binary(target_id) do
    record_with_alias(session_uri, target_id)
  end

  @doc """
  Confirm a verification token (the web endpoint's job, delegated here so
  the token logic has ONE home). Flips the binding to `verified`. Returns
  `{:ok, row} | {:error, :invalid | :expired}`.
  """
  @spec confirm(String.t()) :: {:ok, InboundBinding.t()} | {:error, :invalid | :expired}
  def confirm(raw_token) when is_binary(raw_token), do: InboundBinding.confirm(raw_token)

  # ----- internals -----------------------------------------------------------

  defp record_with_alias(session_uri, target_id, attempt \\ 0)

  defp record_with_alias(_session_uri, _target_id, attempt) when attempt >= @max_alias_retries do
    {:error, :alias_generation_exhausted}
  end

  defp record_with_alias(%URI{} = session_uri, target_id, attempt) do
    binding_row_id = BindingRow.row_id(session_uri, @adapter_id, target_id)
    local_address = mint_alias(session_uri)
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)

    case InboundBinding.record(%{
           binding_row_id: binding_row_id,
           local_address: local_address,
           session_uri: URI.to_string(session_uri),
           target_id: target_id,
           workspace_uri: workspace_uri
         }) do
      {:ok, {row, raw}} ->
        {:ok, {row, raw}}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :local_address) do
          # Alias collision — regenerate + retry.
          record_with_alias(session_uri, target_id, attempt + 1)
        else
          # session_uri unique (already an email binding on this session) or
          # other validation error — not retryable.
          {:error, {:inbound_binding_insert_failed, errors}}
        end
    end
  end

  # A human-friendly-ish, GLOBALLY-unique alias on the sending domain.
  # `<workspace-hint>-<short-id>@ezagent.chat` — the slug is cosmetic;
  # inbound security does NOT depend on it being unguessable (auth is
  # verified-bind + DMARC + From-match). Uniqueness is enforced by the
  # `local_address` unique index + this regenerate-retry.
  defp mint_alias(%URI{} = session_uri) do
    hint =
      case Ezagent.URI.workspace_name(session_uri) do
        {:ok, name} -> slugify(name)
        _ -> "s"
      end

    short = :crypto.strong_rand_bytes(5) |> Base.url_encode64(padding: false) |> slugify()
    "#{hint}-#{short}@#{@alias_domain}"
  end

  defp slugify(s) when is_binary(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "x"
      slug -> slug
    end
  end

  defp send_verification_email(target_id, raw_token) do
    link = confirm_base_url() <> "/auth/email/confirm/" <> raw_token

    subject = "Confirm your ezagent email binding"

    body =
      "You (or someone) bound this email address to an ezagent session.\n\n" <>
        "Confirm to start receiving + replying to that session by email:\n\n" <>
        link <>
        "\n\nIf you did not request this, ignore this email — nothing will be sent.\n"

    case Ezagent.Email.send(target_id, subject, body) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Email.Verification: verification email to #{target_id} failed " <>
            "(binding stays pending): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp confirm_base_url do
    Application.get_env(:ezagent_plugin_email, :verification_base_url, "http://localhost")
  end
end

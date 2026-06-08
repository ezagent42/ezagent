defmodule Ezagent.Socialware.CustomerFeed do
  @moduledoc """
  Gated customer projection for socialware sessions.

  Customer routes must use this module rather than raw MessageStore,
  Publisher, or ExternalMirror streams.
  """

  alias Ezagent.{Behavior.Surface, MessageStore}
  alias Ezagent.Socialware.CustomerAuth
  alias Ezagent.URI, as: EzURI

  @history_limit 100
  @approved_scan_limit 500

  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = session_uri), do: "socialware:customer:" <> URI.to_string(session_uri)

  @spec snapshot(URI.t(), String.t()) :: {:ok, map()} | {:error, :unauthorized}
  def snapshot(%URI{} = session_uri, token) do
    with {:ok, workspace_uri} <- workspace(session_uri),
         :ok <- CustomerAuth.authorize(token, session_uri, workspace_uri) do
      {:ok,
       %{
         messages: MessageStore.committed_customer_visible(session_uri, @history_limit),
         page: customer_page(session_uri)
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @spec history(URI.t(), String.t()) :: {:ok, map()} | {:error, :unauthorized}
  def history(%URI{} = session_uri, token) do
    with {:ok, workspace_uri} <- workspace(session_uri),
         :ok <- CustomerAuth.authorize(token, session_uri, workspace_uri) do
      {:ok, %{messages: MessageStore.committed_customer_visible(session_uri, @history_limit)}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Whether `upload_uri` (a `resource://<ws>/uploads/<name>` URI) is an APPROVED
  attachment in `session_uri` — i.e. it appears in the decoded `attachments` of
  some committed, `customer_visible` message in that session
  (Resource-unification P2a / OI-1).

  This is the **approved-only gate** for the external customer-feed: a download
  token is minted only when this returns `true`, AND it is re-checked at serve
  time (serve-time re-validation — a revocation lever beyond the token TTL: if an
  operator flips the message back to `operator_only` via
  `MessageStore.mark_visibility/2`, an already-minted token stops working).

  Unlike the internal participation check this is purely visibility-based: a feed
  viewer has no session/caps, so "approved for the customer" is the only authority.
  """
  @spec approved_attachment?(URI.t(), URI.t()) :: boolean()
  def approved_attachment?(%URI{} = session_uri, %URI{scheme: "resource"} = upload_uri) do
    if EzURI.type?(upload_uri, :uploads) do
      session_uri
      |> MessageStore.committed_customer_visible(@approved_scan_limit)
      |> Enum.any?(&message_attaches?(&1, upload_uri))
    else
      false
    end
  end

  def approved_attachment?(_session_uri, _upload_uri), do: false

  @doc """
  Mint a signed download token for `upload_uri` ONLY if it is an approved
  attachment in `session_uri` (the approved-only gate). Returns
  `{:ok, token}` | `{:error, :not_approved}`. The `mint_fun` is injected (the
  socialware domain does not depend on the web token module) — pass
  `&EzagentWeb.Uploads.UploadToken.mint!/1` (or `/2` partially applied).
  """
  @spec mint_approved_token(URI.t(), URI.t(), (URI.t() -> String.t())) ::
          {:ok, String.t()} | {:error, :not_approved}
  def mint_approved_token(%URI{} = session_uri, %URI{} = upload_uri, mint_fun)
      when is_function(mint_fun, 1) do
    if approved_attachment?(session_uri, upload_uri) do
      {:ok, mint_fun.(upload_uri)}
    else
      {:error, :not_approved}
    end
  end

  @doc """
  Resolve a customer-feed attachment download to its on-disk path, doing ALL
  feed-side authorization (Resource-unification P2a / OI-1) — the external bearer
  path for viewers with NO session/caps:

    1. **session auth** — `CustomerAuth.authorize/3` proves the caller holds a
       valid token for `session_uri` + its workspace (the customer-feed token);
    2. **file binding** — `upload_uri` is the URI the signed `UploadToken` was
       bound to (passed in already-verified by the caller);
    3. **serve-time approved-only re-validation** — `approved_attachment?/2`
       re-confirms the attachment is STILL a committed customer-visible item in
       this session (a revocation lever beyond the upload-token TTL);
    4. **resolve** — under the SESSION's workspace (the authenticated subject for
       the feed, derived from the session binding, NOT from the upload URI), via
       the hardened uploads resolver (ws-segment authority + R-2 traversal guard).

  Returns `{:ok, path}` | `{:error, :unauthorized}` (fail closed on any step).
  `resolve_fun` is injected so the socialware domain does not depend on the web
  uploads module — pass `&Ezagent.Uploads.resolve/2`.
  """
  @spec authorized_attachment_path(
          URI.t(),
          String.t(),
          URI.t(),
          (URI.t(), map() -> {:ok, String.t()} | :none | {:error, term()})
        ) :: {:ok, String.t()} | {:error, :unauthorized}
  def authorized_attachment_path(%URI{} = session_uri, token, %URI{} = upload_uri, resolve_fun)
      when is_binary(token) and is_function(resolve_fun, 2) do
    with {:ok, workspace_uri} <- workspace(session_uri),
         :ok <- CustomerAuth.authorize(token, session_uri, workspace_uri),
         true <- approved_attachment?(session_uri, upload_uri),
         {:ok, ws_name} <- EzURI.workspace_name(workspace_uri),
         {:ok, path} <- resolve_fun.(upload_uri, %{workspace: ws_name}) do
      {:ok, path}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp message_attaches?(message, %URI{} = upload_uri) do
    target = EzURI.stable_key(upload_uri)

    message
    |> attachments_of()
    |> Enum.any?(fn att -> attachment_key(att) == target end)
  end

  defp attachments_of(%{body: %{attachments: list}}) when is_list(list), do: list
  defp attachments_of(%{body: %{"attachments" => list}}) when is_list(list), do: list
  defp attachments_of(_), do: []

  defp attachment_key(%URI{} = uri), do: EzURI.stable_key(uri)

  defp attachment_key(s) when is_binary(s) do
    EzURI.stable_key(EzURI.new!(s))
  rescue
    ArgumentError -> nil
  end

  defp attachment_key(_), do: nil

  defp workspace(session_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, workspace_uri} -> {:ok, workspace_uri}
      :error -> {:error, :unbound_session}
    end
  end

  defp customer_page(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, surface} -> Surface.customer_tree(surface)
      _ -> nil
    end
  end
end

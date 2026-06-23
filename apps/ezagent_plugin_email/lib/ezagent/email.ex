defmodule Ezagent.Email do
  @moduledoc """
  Facade for ezagent.chat email (task #88, CLI-only). `send/4` goes out over SMTP
  (Swoosh, `smtp_config` from `Ezagent.AppSettings`); `inbox/1`/`fetch/2`/
  `delete/2` read the configured inbox backend (CF Email Worker pull; IMAP
  reserved). Returns tagged tuples; the CLI maps them to status output.

  ## RFC 5322 threading headers (#88 PR-1 / HIGH 5)

  `send/4` accepts three optional threading headers so the ExternalMirror
  email Binding (`Ezagent.Email.Binding`) can thread a session ↔ email
  conversation in the human's mail client:

  - `:message_id`  — the `Message-ID` stamped on THIS outbound mail.
  - `:in_reply_to` — the `In-Reply-To` header (the immediate parent).
  - `:references`  — the `References` header (the full chain, growing).

  These map onto `Swoosh.Email.header/3`. They are backward-compatible:
  absent opts emit no header (identical to the pre-threading behavior).
  """
  import Swoosh.Email
  alias Ezagent.Email.Mailer

  @default_from "no-reply@ezagent.chat"

  @spec send(String.t(), String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def send(to, subject, body, opts \\ [])
      when is_binary(to) and is_binary(subject) and is_binary(body) do
    if mail_ready?() do
      from = Keyword.get(opts, :from) || configured_from()

      email =
        new()
        |> to(to)
        |> from({"Ezagent", from})
        |> subject(subject)
        |> text_body(body)
        |> maybe_html(opts[:html])
        |> maybe_threading_headers(opts)

      deliver_built(email)
    else
      {:error, :mail_not_configured}
    end
  end

  @spec inbox(keyword()) :: {:ok, [map()]} | {:error, term()}
  def inbox(opts \\ []), do: with_backend(&backend().list(&1, opts))

  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(key, _opts \\ []) when is_binary(key), do: with_backend(&backend().fetch(&1, key))

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, _opts \\ []) when is_binary(key), do: with_backend(&backend().delete(&1, key))

  # --- send helpers ---

  defp maybe_html(email, nil), do: email
  defp maybe_html(email, html) when is_binary(html), do: html_body(email, html)

  # #88 PR-1 (HIGH 5): stamp RFC 5322 threading headers when present.
  # Each is independently optional → absent opt emits no header (backward
  # compatible with pre-threading callers). `Swoosh.Email.header/3` raises
  # ArgumentError on a non-binary value, so we only pipe when the opt is a
  # binary.
  defp maybe_threading_headers(email, opts) do
    email
    |> maybe_header("Message-ID", opts[:message_id])
    |> maybe_header("In-Reply-To", opts[:in_reply_to])
    |> maybe_header("References", opts[:references])
  end

  defp maybe_header(email, _name, nil), do: email
  defp maybe_header(email, _name, ""), do: email
  defp maybe_header(email, name, value) when is_binary(value), do: header(email, name, value)
  defp maybe_header(email, _name, _value), do: email

  defp configured_adapter, do: Application.get_env(:ezagent_plugin_email, Mailer, [])[:adapter]

  # Local (dev) + Test (test) are "non-SMTP": always ready, do NOT touch the DB.
  # Only the SMTP adapter reads smtp_config from AppSettings.
  defp non_smtp_adapter? do
    configured_adapter() in [Swoosh.Adapters.Local, Swoosh.Adapters.Test]
  end

  defp mail_ready? do
    if non_smtp_adapter?(), do: true, else: Ezagent.AppSettings.smtp_configured?()
  end

  defp configured_from do
    if non_smtp_adapter?() do
      @default_from
    else
      case Ezagent.AppSettings.get("smtp_config") do
        %{"from_address" => addr} when is_binary(addr) and addr != "" -> addr
        _ -> @default_from
      end
    end
  end

  defp deliver_built(email) do
    if non_smtp_adapter?() do
      Mailer.deliver(email)
    else
      Mailer.deliver(
        email,
        Ezagent.Mail.SmtpOpts.from_config(Ezagent.AppSettings.get("smtp_config"))
      )
    end
  end

  # --- inbox backend dispatch ---

  defp with_backend(fun) do
    case Ezagent.Email.Config.load() do
      {:ok, %{"backend" => "cf_worker"} = cfg} -> fun.(cfg)
      {:ok, %{"backend" => _other}} -> {:error, :backend_not_implemented}
      {:error, _} = err -> err
    end
  end

  defp backend, do: Ezagent.Email.Inbox.CFWorker
end

defmodule Mix.Tasks.Ezagent.Email do
  @shortdoc "Send / read / delete ezagent.chat email (task #88)"
  @moduledoc """
  Operator CLI for ezagent.chat email. Runs in-VM (trusted boundary).

      mix ezagent.email send --to <addr> --subject <s> --body <b> [--html <h>]
      mix ezagent.email inbox [--to <addr>] [--limit N]
      mix ezagent.email fetch <key>
      mix ezagent.email delete <key>

  Send uses SMTP (`smtp_config` in AppSettings). Inbox/fetch/delete read
  `<credentials>/email_inbox_config.json` (or `EZAGENT_EMAIL_PULL_URL` /
  `EZAGENT_EMAIL_PULL_TOKEN`).
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_email)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [to: :string, subject: :string, body: :string, html: :string, limit: :integer]
      )

    case positional do
      ["send" | _] -> do_send(opts)
      ["inbox" | _] -> do_inbox(opts)
      ["fetch", key | _] -> do_fetch(key)
      ["delete", key | _] -> do_delete(key)
      _ -> fail("usage: see `mix help ezagent.email`")
    end
  end

  defp do_send(opts) do
    to = req(opts, :to)
    subject = req(opts, :subject)
    body = req(opts, :body)

    case Ezagent.Email.send(to, subject, body, Keyword.take(opts, [:html])) do
      {:ok, _} -> Mix.shell().info("sent to #{to}")
      {:error, reason} -> fail("send failed: #{inspect(reason)}")
    end
  end

  defp do_inbox(opts) do
    case Ezagent.Email.inbox(Keyword.take(opts, [:to, :limit])) do
      {:ok, emails} ->
        Mix.shell().info("#{length(emails)} message(s):")

        Enum.each(emails, fn e ->
          Mix.shell().info("  #{e["key"]}  | #{e["from"]} | #{e["subject"]} | #{e["receivedAt"]}")
        end)

      {:error, reason} ->
        fail("inbox failed: #{inspect(reason)}")
    end
  end

  defp do_fetch(key) do
    case Ezagent.Email.fetch(key) do
      {:ok, e} ->
        Mix.shell().info("From: #{e["from"]}\nTo: #{e["to"]}\nSubject: #{e["subject"]}\n\n#{e["text"]}")

      {:error, reason} ->
        fail("fetch failed: #{inspect(reason)}")
    end
  end

  defp do_delete(key) do
    case Ezagent.Email.delete(key) do
      :ok -> Mix.shell().info("deleted #{key}")
      {:error, reason} -> fail("delete failed: #{inspect(reason)}")
    end
  end

  defp req(opts, k) do
    case Keyword.get(opts, k) do
      nil -> fail("missing --#{k}")
      v -> v
    end
  end

  defp fail(msg) do
    Mix.shell().error(msg)
    exit({:shutdown, 1})
  end
end

defmodule Ezagent.Email.Config do
  @moduledoc """
  Loads the inbound-email pull config for the CLI. Reads
  `<credentials>/email_inbox_config.json` (same `system://credentials/...`
  location as `smtp_config.json`), with env-var overrides
  (`EZAGENT_EMAIL_PULL_URL`, `EZAGENT_EMAIL_PULL_TOKEN`, `EZAGENT_EMAIL_BACKEND`).
  Returns `{:error, :inbox_not_configured}` unless a non-blank `pull_url` +
  `pull_token` are present. The token is read from disk/env only — never logged.
  """

  @spec load() :: {:ok, map()} | {:error, :inbox_not_configured}
  def load do
    file = read_file()

    cfg = %{
      "backend" => env("EZAGENT_EMAIL_BACKEND") || Map.get(file, "backend") || "cf_worker",
      "pull_url" => env("EZAGENT_EMAIL_PULL_URL") || Map.get(file, "pull_url") || "",
      "pull_token" => env("EZAGENT_EMAIL_PULL_TOKEN") || Map.get(file, "pull_token") || ""
    }

    if blank?(cfg["pull_url"]) or blank?(cfg["pull_token"]) do
      {:error, :inbox_not_configured}
    else
      {:ok, cfg}
    end
  end

  defp read_file do
    with {:ok, path} <- safe_path(),
         {:ok, body} <- File.read(path),
         {:ok, %{} = json} <- Jason.decode(body) do
      json
    else
      _ -> %{}
    end
  end

  defp safe_path do
    {:ok, Ezagent.System.FsResolver.path!(Ezagent.URI.system("credentials", "email_inbox_config.json"))}
  rescue
    _ -> :error
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
end

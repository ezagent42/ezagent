defmodule Ezagent.PluginCc.Template.OnboardingBootstrap do
  @moduledoc """
  §5.B follow-up (b) — DURABLE suppression of claude's first-run onboarding flow
  for headless cc agents.

  claude v2.1.x runs a first-run flow (theme picker → "Select login method") the
  first time it starts against a config home that has NOT been marked onboarded —
  **even when a valid `.credentials.json` is already materialized into
  `CLAUDE_CONFIG_DIR`** (the §5.B credential-cascade live finding, 2026-06-07). A
  headless PTY cannot answer those dialogs, so the spawn hangs and the bridge never
  binds.

  The PtyServer auto-prompt scanner (`:theme_dialog` / `:login_method_dialog`) is a
  best-effort SAFETY NET, but the reliable fix (verified in memory
  `project_headless_claude_startup_dialogs`) is to set claude's OWN config keys so
  the first-run flow never starts: top-level `hasCompletedOnboarding: true` (+ a
  default `theme`) in `<CLAUDE_CONFIG_DIR>/.claude.json`.

  `ensure/1` is idempotent + non-destructive: it MERGES into an existing
  `.claude.json` (never clobbering an operator/agent-chosen `theme` or any other
  key) and writes the file 0600. It runs on BOTH the fresh-spawn and the respawn
  paths so the marker survives the agent's own restarts.
  """

  require Logger

  @claude_json_relpath ".claude.json"
  @default_theme "dark"

  @doc """
  Ensure `<config_dir>/.claude.json` marks claude onboarding complete.

  `nil` config_dir (agent has no isolated config home → claude uses `~/.claude`)
  is a no-op. Returns `:ok` or `{:error, reason}` (corrupt existing file / write
  failure).
  """
  @spec ensure(String.t() | nil) :: :ok | {:error, term()}
  def ensure(nil), do: :ok

  def ensure(config_dir) when is_binary(config_dir) do
    path = Path.join(config_dir, @claude_json_relpath)

    with {:ok, existing} <- read_existing(path),
         merged = merge_onboarding(existing),
         :ok <- write_private(path, Jason.encode!(merged, pretty: true)) do
      :ok
    end
  end

  # Best-effort wrapper for the spawn path: never tears the agent down (the
  # PtyServer scanner is the fallback). Logs + emits telemetry on failure so the
  # degraded state is observable, but returns `:ok` so the `with` chain proceeds.
  @doc false
  @spec try_ensure(String.t() | nil, URI.t()) :: :ok
  def try_ensure(config_dir, %URI{} = agent_uri) do
    case ensure(config_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "cc.agent: onboarding-marker bootstrap failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)} — the agent may stall at " <>
            "claude's first-run theme/login dialog; the PtyServer auto-prompt scanner " <>
            "is the fallback. (best-effort, §5.B follow-up b)"
        )

        :telemetry.execute(
          [:ezagent, :cc, :onboarding_bootstrap, :failed],
          %{count: 1},
          %{agent_uri: agent_uri, reason: reason, config_dir: config_dir}
        )

        :ok
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{} = json} -> {:ok, json}
          {:ok, _non_object} -> {:error, {:claude_json_not_object, path}}
          {:error, %Jason.DecodeError{}} -> {:error, {:claude_json_undecodable, path}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:claude_json_read_failed, reason}}
    end
  end

  # Set the onboarding-completion marker; only default the theme when ABSENT so an
  # operator/agent-chosen theme is preserved.
  defp merge_onboarding(existing) when is_map(existing) do
    existing
    |> Map.put("hasCompletedOnboarding", true)
    |> Map.put_new("theme", @default_theme)
  end

  # Write through a private temp (chmod 0600 BEFORE content) then atomic rename, so
  # the file is never group/world-readable even briefly. (Same pattern as
  # CredentialRefresh.write_private/2.)
  defp write_private(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

      result =
        with :ok <- File.touch(tmp),
             :ok <- File.chmod(tmp, 0o600),
             :ok <- File.write(tmp, content),
             :ok <- File.rename(tmp, path) do
          :ok
        end

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, {:claude_json_write_failed, reason}}
      end
    end
  end
end

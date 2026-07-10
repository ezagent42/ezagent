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

  ## Two concerns materialized into `.claude.json`

  This module now materializes TWO independent `.claude.json` concerns:

  1. **First-run dialog suppression** (`merge_onboarding/2`, the original §5.B
     purpose) — `hasCompletedOnboarding` + `theme` + the per-project trust gates.
  2. **Channel-inject entitlement** (`merge_channel_features/1`) — the
     `claude/channel` inject capability that lets a server-pushed `@mention`
     reach the agent is gated by claude's `tengu_harbor` GrowthBook feature (a
     first-party account entitlement, normally fetched from GrowthBook and cached
     under `cachedGrowthBookFeatures`). A cc agent on a non-Anthropic backend
     (deepseek/GLM) never fetches it, so mentions are silently dropped. We
     materialize the cache directly (`tengu_harbor: true` + a
     `cachedGrowthBookFeaturesAt` timestamp) so channel registration succeeds
     WITHOUT any Anthropic OAuth. Live-proven on canary: sidecar logs "Channel
     notifications registered" and the `@mention` reply fires. Cache-only,
     durable across respawns (a 30-day-stale timestamp still worked).

  Scope: this runs for EVERY cc agent, because every cc agent launches with
  `--dangerously-load-development-channels server:esr-bridge` (see
  `SpawnPlan.build_claude_cmd/3`) and this bootstrap is the single chokepoint the
  cc spawn/respawn path reaches — so "all cc agents" == "agents that launch with
  the dev-channels flag". No per-flavor branch is needed (机制 ≠ 业务).
  """

  require Logger

  @claude_json_relpath ".claude.json"
  @default_theme "dark"
  @channel_features_relpath "channel_growthbook_features.json"

  @doc """
  Ensure `<config_dir>/.claude.json` marks claude onboarding complete.

  `nil` config_dir (agent has no isolated config home → claude uses `~/.claude`)
  is a no-op. Returns `:ok` or `{:error, reason}` (corrupt existing file / write
  failure).
  """
  @spec ensure(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def ensure(config_dir, opts \\ [])
  def ensure(nil, _opts), do: :ok

  def ensure(config_dir, opts) when is_binary(config_dir) do
    path = Path.join(config_dir, @claude_json_relpath)

    with {:ok, existing} <- read_existing(path),
         merged = merge_onboarding(existing, Keyword.get(opts, :project_cwd)),
         merged = merge_channel_features(merged),
         :ok <- write_private(path, Jason.encode!(merged, pretty: true)) do
      :ok
    end
  end

  # Best-effort wrapper for the spawn path: never tears the agent down (the
  # PtyServer scanner is the fallback). Logs + emits telemetry on failure so the
  # degraded state is observable, but returns `:ok` so the `with` chain proceeds.
  @doc false
  @spec try_ensure(String.t() | nil, URI.t(), keyword()) :: :ok
  def try_ensure(config_dir, %URI{} = agent_uri, opts \\ []) do
    result =
      try do
        ensure(config_dir, opts)
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      end

    case result do
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
  # operator/agent-chosen theme is preserved. When a `project_cwd` is supplied,
  # ALSO pre-set the PROJECT-scoped trust gates under `projects.<cwd>` so the
  # headless cc PTY never stalls at claude 2.x's per-project startup dialogs
  # (#505) — these are SEPARATE from onboarding and from
  # `--dangerously-skip-permissions`, and a headless PTY cannot answer them:
  #   * `hasTrustDialogAccepted`            — "Do you trust this folder?"
  #   * `hasClaudeMdExternalIncludesApproved` — "Allow external CLAUDE.md imports?"
  #   * `hasCompletedProjectOnboarding`     — per-project first-run flow
  #   * `enableAllProjectMcpServers`        — "New MCP server found" trust prompt
  # The PtyServer auto-prompt scanner remains the fallback for any prompt a config
  # key does not suppress (e.g. the bypass-permissions acceptance). Pre-setting is
  # deterministic (no scan / no TUI-text fragility) — the task's preferred fix (a).
  defp merge_onboarding(existing, project_cwd) when is_map(existing) do
    existing
    |> Map.put("hasCompletedOnboarding", true)
    |> Map.put_new("theme", @default_theme)
    |> maybe_put_project_trust(project_cwd)
  end

  defp maybe_put_project_trust(map, project_cwd)
       when is_binary(project_cwd) and project_cwd != "" do
    key = Path.expand(project_cwd)
    # Defensive: a hand-edited `.claude.json` could carry a non-object `projects`
    # or project entry. Treat any non-map as absent rather than letting `Map.get`
    # raise out of the best-effort spawn path (codex review).
    projects = as_map(Map.get(map, "projects"))
    project = as_map(Map.get(projects, key))

    project =
      project
      |> Map.put("hasTrustDialogAccepted", true)
      |> Map.put("hasClaudeMdExternalIncludesApproved", true)
      |> Map.put("hasCompletedProjectOnboarding", true)
      |> Map.put("enableAllProjectMcpServers", true)

    Map.put(map, "projects", Map.put(projects, key, project))
  end

  defp maybe_put_project_trust(map, _), do: map

  # Channel-inject entitlement (see moduledoc §"Two concerns"). Merge
  # `tengu_harbor: true` INTO any existing `cachedGrowthBookFeatures` map so the
  # `claude/channel` inject capability registers on a non-Anthropic backend.
  #
  #   * `tengu_harbor` is force-set true (idempotent) — this is the ONE feature
  #     the channel-registration gate needs; merged non-destructively so a
  #     pre-existing full GrowthBook blob (e.g. copied creds) is preserved.
  #   * `cachedGrowthBookFeaturesAt` is set-IF-ABSENT (a fresh ms timestamp on
  #     first materialization, preserved thereafter). Set-if-absent keeps the
  #     write idempotent AND is proven-safe: a 30-day-stale timestamp still
  #     registered channels on canary (claude uses the cache; the best-effort
  #     GrowthBook refresh that a non-Anthropic backend can't complete does not
  #     invalidate it).
  defp merge_channel_features(map) when is_map(map) do
    features =
      map
      |> Map.get("cachedGrowthBookFeatures")
      |> as_map()
      |> Map.merge(channel_features())

    map
    |> Map.put("cachedGrowthBookFeatures", features)
    |> Map.put_new("cachedGrowthBookFeaturesAt", System.os_time(:millisecond))
  end

  # COMMITTED asset (never the host `~/.claude.json` — the container has none).
  # Read at runtime (same pattern as SpawnPlan.mandatory_settings_path/0) so the
  # minimal `{"tengu_harbor": true}` payload stays human-editable + reversible:
  # if it ever proves insufficient on a live agent, drop the full GrowthBook
  # feature blob into the JSON — no code change.
  defp channel_features do
    :code.priv_dir(:ezagent_plugin_cc)
    |> Path.join(@channel_features_relpath)
    |> File.read!()
    |> Jason.decode!()
  end

  defp as_map(m) when is_map(m), do: m
  defp as_map(_), do: %{}

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

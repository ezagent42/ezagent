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

  ## Three concerns materialized into `.claude.json`

  This module materializes THREE independent `.claude.json` concerns:

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
  3. **Custom-API-key confirm pre-approval** (`merge_api_key_approvals/1`) —
     claude's first-run flow shows a `Detected a custom API key in your
     environment / Do you want to use this API key?` CONFIRM dialog whenever it
     picks up an `ANTHROPIC_API_KEY` env var that is not yet on its
     `customApiKeyResponses.approved` allowlist. A headless PTY cannot answer it,
     so the spawn would hang. Our deepseek/proxy agents authenticate via
     `ANTHROPIC_AUTH_TOKEN` (NOT `ANTHROPIC_API_KEY`), which claude checks on a
     SEPARATE branch that never enters this confirm — so this is a
     BELT-AND-SUSPENDERS guard for the failure mode where a deploy erroneously
     sets `ANTHROPIC_API_KEY` instead of `ANTHROPIC_AUTH_TOKEN`. claude stores the
     approval as the key's LAST 20 CHARS (verified in the 2.1.206 binary:
     `D4(e) = e.slice(-20)`, read by `customApiKeyResponses.approved?.includes(D4(t))`),
     so we pre-seed that exact identifier. The spawned claude INHERITS the BEAM's
     ambient OS env (`PtyServer.build_env/1` adds `cmd_env` on top of normal
     OS-process inheritance and never strips it), so the `ANTHROPIC_API_KEY` we
     read here via `System.get_env/1` is the exact key claude will use. No-op when
     `ANTHROPIC_API_KEY` is unset/empty (the normal case) — this only ever writes
     when the erroneous env is actually present. Deterministic (no scan / no
     TUI-text fragility); the PtyServer scanner is not the mechanism here.

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
         merged = merge_api_key_approvals(merged),
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

  # Concern 3 (see moduledoc §"Three concerns"). Pre-approve an env-provided
  # `ANTHROPIC_API_KEY` so claude's first-run custom-API-key CONFIRM dialog never
  # appears (a headless PTY can't answer it → hang). No-op when the env var is
  # absent/empty — the normal case for our deepseek/proxy agents, which use
  # `ANTHROPIC_AUTH_TOKEN`. This is the belt-and-suspenders guard for a deploy
  # that erroneously sets `ANTHROPIC_API_KEY`.
  #
  # Merges NON-DESTRUCTIVELY into any existing `customApiKeyResponses`: the key's
  # approval id is appended to `approved` only if absent (idempotent across
  # respawns), a pre-existing `rejected` list is preserved, and an
  # operator-approved key from a copied `.claude.json` is never dropped.
  defp merge_api_key_approvals(map) when is_map(map) do
    case api_key_from_env() do
      nil ->
        map

      key ->
        id = api_key_approval_id(key)
        responses = as_map(Map.get(map, "customApiKeyResponses"))
        approved = as_list(Map.get(responses, "approved"))
        approved = if id in approved, do: approved, else: approved ++ [id]

        responses =
          responses
          |> Map.put("approved", approved)
          |> Map.put("rejected", as_list(Map.get(responses, "rejected")))

        Map.put(map, "customApiKeyResponses", responses)
    end
  end

  defp api_key_from_env do
    case System.get_env("ANTHROPIC_API_KEY") do
      k when is_binary(k) and k != "" -> k
      _ -> nil
    end
  end

  # claude 2.1.206 stores the approval identifier as the key's LAST 20 CHARACTERS
  # (`D4(e) = e.slice(-20)`; read back by `approved?.includes(D4(t))`). We MUST
  # produce byte-for-byte the same identifier or the pre-seed won't satisfy the
  # gate. `String.slice/3` with a `-20` offset matches JS `slice(-20)` exactly:
  # last 20 chars for a longer key, the whole string for a key ≤ 20 chars.
  defp api_key_approval_id(key) when is_binary(key), do: String.slice(key, -20, 20)

  defp as_list(l) when is_list(l), do: l
  defp as_list(_), do: []

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

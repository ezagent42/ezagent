defmodule EzagentPluginAutoservice.Assembly.Refresh do
  @moduledoc """
  Post-publish agent refresh for the AutoService v2 vertical.

  `refresh_agents/1` is called after a successful `Publisher.publish/2` to
  bring running agents in sync with the newly-published release content.

  ## Slow cc agent

  1. `TenantContent.provision_context(tid, "slow", source: :release)` —
     re-renders the soul + skill-index from the new `_current` release.
  2. Rewrites `<work_dir>/CLAUDE.md` with the fresh content.
     The slow agent reads its soul from work-dir CLAUDE.md; the rewrite is
     the minimal correct update path.
  3. For each live slow cc agent, triggers a sanctioned PTY respawn via
     `Ezagent.PluginCc.Template.CcAgent.ensure_subprocess_alive/2` so the
     agent re-reads CLAUDE.md immediately. Respawn data is read from the
     live Kind's `:sandbox` slice (non-deadlocking — called from outside
     the Kind's process). Falls back to the snapshot store for dormant Kinds.
     The respawn deliberately does NOT re-materialize config_dir — that is
     acceptable and by design; we only need the agent to re-read work-dir
     CLAUDE.md.

  ## Fast curl agent

  Dispatches `curl_agent.configure` with the updated `system_prompt` from
  `provision_context(tid, "fast", source: :release).system_prompt` to all
  live fast curl agents for this tenant.

  ## Failure semantics

  Returns `:ok` when CLAUDE.md is written successfully (the content-rewrite
  is the gate). Respawn and configure errors are logged as warnings and are
  non-fatal — agents pick up fresh content on their next natural restart.
  Returns `{:error, reason}` only on fatal failures (provision fails or
  CLAUDE.md write fails).
  """

  alias EzagentPluginContent.TenantContent

  require Logger

  @doc """
  Refresh running agents for tenant `tid` after a publish.

  Rewrites the slow agent's `work_dir/CLAUDE.md` from the new release,
  triggers a sanctioned respawn on live slow agents, and updates the fast
  curl agent's `system_prompt` via dispatch.

  Returns `:ok` on success (including degraded-but-non-fatal respawn/configure
  errors). Returns `{:error, reason}` on fatal provision or write failures.
  """
  @spec refresh_agents(String.t()) :: :ok | {:error, term()}
  def refresh_agents(tid) when is_binary(tid) do
    with :ok <- refresh_slow(tid) do
      refresh_fast(tid)
    end
  end

  # ---------------------------------------------------------------------------
  # Slow agent refresh: rewrite CLAUDE.md + respawn live agents
  # ---------------------------------------------------------------------------

  defp refresh_slow(tid) do
    case TenantContent.provision_context(tid, "slow", source: :release) do
      {:ok, sctx} ->
        claude_md_path = Path.join(sctx.work_dir, "CLAUDE.md")
        content = sctx.claude_md || ""

        _ = File.mkdir_p(sctx.work_dir)

        case File.write(claude_md_path, content) do
          :ok ->
            Logger.info(
              "Refresh: slow CLAUDE.md rewritten — #{claude_md_path} (#{byte_size(content)} bytes)"
            )

            # Respawn all live slow cc agents for this tenant (best-effort).
            live_agents_for(tid, "cs-slow-")
            |> Enum.each(fn uri -> respawn_slow_agent(uri) end)

            :ok

          {:error, reason} ->
            {:error, {:slow_claude_md_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:slow_provision_failed, reason}}
    end
  end

  @doc """
  Trigger a sanctioned PTY respawn for a single slow cc agent.

  Uses `Ezagent.PluginCc.Template.CcAgent.ensure_subprocess_alive/2` — the
  ONLY public entrypoint for PTY respawn. Respawn data is read from the live
  Kind's `:sandbox` slice or, if dormant, from the snapshot store.

  Returns `:ok` (non-fatal on respawn failure — logs a warning instead).
  """
  @spec respawn_slow_agent(URI.t()) :: :ok
  def respawn_slow_agent(%URI{} = slow_uri) do
    respawn_data = load_respawn_data(slow_uri)

    if is_map(respawn_data) do
      result =
        Ezagent.PluginCc.Template.CcAgent.ensure_subprocess_alive(slow_uri, respawn_data)

      case result do
        :ok ->
          Logger.info("Refresh: slow agent respawned — #{URI.to_string(slow_uri)}")

        {:error, reason} ->
          Logger.warning(
            "Refresh: slow agent respawn (non-fatal) — #{URI.to_string(slow_uri)}: #{inspect(reason)}"
          )
      end

      :ok
    else
      Logger.info(
        "Refresh: no respawn data for #{URI.to_string(slow_uri)} " <>
          "(not yet a cc agent or dormant — will pick up CLAUDE.md on next start)"
      )

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Fast agent refresh: update system_prompt via curl_agent.configure dispatch
  # ---------------------------------------------------------------------------

  defp refresh_fast(tid) do
    case TenantContent.provision_context(tid, "fast", source: :release) do
      {:ok, fctx} ->
        new_prompt = fctx.system_prompt

        if is_binary(new_prompt) and byte_size(new_prompt) > 0 do
          dispatch_fast_configure(tid, new_prompt)
        else
          Logger.info("Refresh: fast has no system_prompt in release content, skipping")
          :ok
        end

      {:error, reason} ->
        # Fast refresh is non-fatal: the slow CLAUDE.md rewrite already happened.
        Logger.warning("Refresh: fast provision failed (non-fatal): #{inspect(reason)}")
        :ok
    end
  end

  defp dispatch_fast_configure(tid, new_prompt) do
    # The CurlAgent's `curl_agent.configure` action updates the system_prompt
    # in-place in the live Kind's persistent state (via {:set, :system_prompt, _} effect).
    ctx = %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
      reply: {:caller_inbox, self()}
    }

    live_fast = live_agents_for(tid, "cs-fast-")

    if live_fast == [] do
      Logger.info("Refresh: no live fast agents for tenant #{tid}, skipping configure dispatch")
    else
      Enum.each(live_fast, fn agent_uri ->
        target =
          Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=curl_agent.configure")

        result =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :call,
            args: %{system_prompt: new_prompt},
            ctx: ctx
          })

        case result do
          {:ok, %{ok: true}} ->
            Logger.info("Refresh: fast agent prompt updated — #{URI.to_string(agent_uri)}")

          other ->
            Logger.warning(
              "Refresh: fast agent configure (non-fatal) — #{URI.to_string(agent_uri)}: #{inspect(other)}"
            )
        end
      end)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Enumerate live entity agents for `tid` whose name starts with `name_prefix`.
  # Uses KindRegistry.list_all/0 — the only available live-listing API.
  defp live_agents_for(tid, name_prefix) do
    Ezagent.KindRegistry.list_all()
    |> Enum.flat_map(fn {uri_str, _pid} ->
      case Ezagent.URI.parse(uri_str) do
        {:ok, %URI{scheme: "entity"} = uri} ->
          case Ezagent.URI.workspace_name(uri) do
            {:ok, ^tid} ->
              case Ezagent.URI.name(uri) do
                {:ok, name} when is_binary(name) ->
                  if String.starts_with?(name, name_prefix), do: [uri], else: []

                _ ->
                  []
              end

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  # Read respawn_template_data from the live Kind's sandbox slice, falling
  # back to the snapshot store for dormant Kinds.
  defp load_respawn_data(%URI{} = agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} ->
        # Kind is alive — read from live slice (non-deadlocking: we are outside
        # the Kind's process; Kind.get_slice/2 is a GenServer.call to that pid).
        case Ezagent.Kind.get_slice(agent_uri, :sandbox) do
          {:ok, sandbox} ->
            normalized = Ezagent.Kind.normalize_slice_view(sandbox)
            Map.get(normalized, :respawn_template_data)

          _ ->
            nil
        end

      :error ->
        # Kind is dormant — read from snapshot store.
        case Ezagent.SnapshotStore.latest(agent_uri) do
          {:ok, %{state: state}} when is_map(state) ->
            sandbox = Ezagent.Kind.normalize_slice_view(Map.get(state, :sandbox, %{}))
            Map.get(sandbox, :respawn_template_data)

          _ ->
            nil
        end
    end
  end
end

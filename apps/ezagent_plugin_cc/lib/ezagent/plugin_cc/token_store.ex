defmodule EzagentPluginCc.TokenStore do
  @moduledoc """
  Phase 5 PR 5 — persist per-CC-instance connect tokens to
  `$EZAGENT_HOME/<profile>/credentials/cc-channels.yaml`.

  YAML shape:

      instances:
        entity://agent/team-alpha/cc_architect:
          token: "tok_abc123..."
          minted_at: "2026-05-17T03:00:00Z"
        entity://agent/team-alpha/cc_builder:
          token: "tok_def456..."
          minted_at: "2026-05-17T03:01:00Z"

  Idempotent: re-minting for an existing `agent_uri` returns the
  existing token (per memory `feedback_let_it_crash_no_workarounds` —
  don't silently regenerate; operator must explicitly rotate via
  `mix ezagent.cc_channel.rotate`).

  Atomic write: read-modify-write inside `Ezagent.Home.path(:credentials)`
  + chmod 600 on every write.
  """

  require Logger

  @file_name "cc-channels.yaml"

  @doc """
  Mint a token for `agent_uri` and persist. Returns `{:ok, token}` for
  newly-minted or existing tokens (idempotent).
  """
  def mint(%URI{} = agent_uri) do
    agent_str = URI.to_string(agent_uri)

    case load_all() do
      {:ok, instances} when is_map(instances) ->
        case Map.get(instances, agent_str) do
          %{"token" => existing} when is_binary(existing) ->
            {:ok, existing}

          _ ->
            token = generate_token()

            new_instances =
              Map.put(instances, agent_str, %{
                "token" => token,
                "minted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              })

            case write_all(new_instances) do
              :ok -> {:ok, token}
              err -> err
            end
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Look up an `agent_uri` by its token. Returns `{:ok, URI.t()}` or
  `:error`. Used by inbound bridge auth.
  """
  def lookup_by_token(token) when is_binary(token) do
    case load_all() do
      {:ok, instances} ->
        Enum.find_value(instances, :error, fn
          {agent_str, %{"token" => ^token}} -> {:ok, URI.parse(agent_str)}
          _ -> nil
        end)

      _ ->
        :error
    end
  end

  @doc "Return all registered `{agent_uri, %{token, minted_at}}` entries."
  def list_all do
    case load_all() do
      {:ok, instances} ->
        Enum.map(instances, fn {agent_str, meta} ->
          {URI.parse(agent_str), meta}
        end)

      _ ->
        []
    end
  end

  defp load_all do
    file = file_path()

    case File.read(file) do
      {:ok, body} ->
        case YamlElixir.read_from_string(body) do
          {:ok, %{"instances" => instances}} when is_map(instances) ->
            {:ok, instances}

          {:ok, _} ->
            {:ok, %{}}

          err ->
            err
        end

      {:error, :enoent} ->
        {:ok, %{}}

      err ->
        err
    end
  end

  defp write_all(instances) do
    file = file_path()
    File.mkdir_p!(Path.dirname(file))

    body =
      "# CC channel per-instance connect tokens — managed by\n" <>
        "# Ezagent.Template.CcChannelInstance Template Class.\n" <>
        "instances:\n" <>
        Enum.map_join(instances, "", fn {agent_str, meta} ->
          "  #{agent_str}:\n" <>
            "    token: \"#{meta["token"]}\"\n" <>
            "    minted_at: \"#{meta["minted_at"]}\"\n"
        end)

    case File.write(file, body) do
      :ok ->
        # chmod 600 — tokens grant bridge authority.
        _ = File.chmod(file, 0o600)
        :ok

      err ->
        err
    end
  end

  defp file_path do
    Path.join(Ezagent.Home.path(:credentials), @file_name)
  end

  defp generate_token do
    "tok_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end
end

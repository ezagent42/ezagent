defmodule Ezagent.AgentBridge.TokenStore do
  @moduledoc """
  Persistent per-agent bridge connect tokens.

  Promoted from `EzagentPluginCc.TokenStore`. The on-disk filename
  remains `$EZAGENT_HOME/<profile>/credentials/cc-channels.yaml` for
  backward compatibility with already-spawned cc agents and operator
  tooling. The YAML shape is unchanged.
  """

  @file_name "cc-channels.yaml"

  alias Ezagent.Authentication.BridgeCredential

  @doc "Authenticate a bridge token only for its transport-bound principal."
  @spec authenticate(BridgeCredential.t()) :: {:ok, URI.t()} | {:error, :invalid_credentials}
  def authenticate(%BridgeCredential{token: token, principal: %URI{} = principal}) do
    if verify_token(principal, token),
      do: {:ok, principal},
      else: {:error, :invalid_credentials}
  end

  def authenticate(_), do: {:error, :invalid_credentials}

  @doc """
  Mint a token for `agent_uri` and persist it.

  Idempotent: existing agent URIs keep their token until an explicit
  rotation flow is added.
  """
  @spec mint(URI.t()) :: {:ok, String.t()} | {:error, term()}
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
  Constant-time VERIFY a `presented` token against `agent_uri`'s persisted
  connect token.

  The secret NEVER leaves this module (Decision C, §2 step 0; codex C-r6-P1):
  exposing the token via a getter would let any co-resident BEAM code read it +
  forge a `SessionManager` `{:run_tool, …}` call as that orchestrator, defeating
  the whole unforgeable-token threat model. SessionManager calls THIS to gate a
  bridge-forwarded token. Returns `true` only on an exact constant-time match;
  `false` for a mismatch, a non-binary token, or an orchestrator with no minted
  token (fail-closed).
  """
  @spec verify_token(URI.t(), term()) :: boolean()
  def verify_token(%URI{} = agent_uri, presented) when is_binary(presented) do
    agent_str = URI.to_string(agent_uri)

    case load_all() do
      {:ok, instances} ->
        case Map.get(instances, agent_str) do
          %{"token" => known} when is_binary(known) -> secure_compare(presented, known)
          _ -> false
        end

      _ ->
        false
    end
  end

  def verify_token(_agent_uri, _presented), do: false

  # Constant-time byte comparison (Plug.Crypto.secure_compare/2 equivalent) — no
  # early exit, so the wall-clock time does not leak how many leading bytes
  # matched. Differing lengths are non-equal but still walk a fixed comparison.
  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and constant_time_compare(left, right, 0)
  end

  defp constant_time_compare(<<x, left::binary>>, <<y, right::binary>>, acc) do
    import Bitwise
    constant_time_compare(left, right, acc ||| bxor(x, y))
  end

  defp constant_time_compare(<<>>, <<>>, acc), do: acc == 0

  @doc "Look up an `agent_uri` by token."
  @spec lookup_by_token(String.t()) :: {:ok, URI.t()} | :error
  def lookup_by_token(token) when is_binary(token) do
    case load_all() do
      {:ok, instances} ->
        Enum.find_value(instances, :error, fn
          {agent_str, %{"token" => ^token}} -> {:ok, Ezagent.URI.new!(agent_str)}
          _ -> nil
        end)

      _ ->
        :error
    end
  end

  @doc "Return all registered `{agent_uri, %{token, minted_at}}` entries."
  @spec list_all() :: [{URI.t(), map()}]
  def list_all do
    case load_all() do
      {:ok, instances} ->
        Enum.map(instances, fn {agent_str, meta} -> {Ezagent.URI.new!(agent_str), meta} end)

      _ ->
        []
    end
  end

  defp load_all do
    file = file_path()

    case File.read(file) do
      {:ok, body} ->
        case YamlElixir.read_from_string(body) do
          {:ok, %{"instances" => instances}} when is_map(instances) -> {:ok, instances}
          {:ok, _} -> {:ok, %{}}
          err -> err
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
        "# Ezagent.AgentBridge.TokenStore.\n" <>
        "instances:\n" <>
        Enum.map_join(instances, "", fn {agent_str, meta} ->
          "  #{agent_str}:\n" <>
            "    token: \"#{meta["token"]}\"\n" <>
            "    minted_at: \"#{meta["minted_at"]}\"\n"
        end)

    case File.write(file, body) do
      :ok ->
        _ = File.chmod(file, 0o600)
        :ok

      err ->
        err
    end
  end

  # Resource-unification P3 (SPEC §10 OI-3): the bridge-token registry is a
  # SINGLE node-global YAML file holding every agent's connect token (keyed by
  # agent URI INSIDE the file) — there is no `<ws>` in its on-disk path, so it is
  # a system-level artifact, addressed `system://credentials/<file>` and resolved
  # through `UriQuery` (NOT a faked `resource://<ws>/...`).
  defp file_path do
    Ezagent.System.FsResolver.path!(Ezagent.URI.system("credentials", @file_name))
  end

  defp generate_token do
    "tok_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end
end

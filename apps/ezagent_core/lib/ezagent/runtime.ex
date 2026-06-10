defmodule Ezagent.Runtime do
  @moduledoc """
  ESR runtime node-name + cookie management (Allen 2026-05-17 directive:
  CLI should reach the runtime via distributed Erlang RPC, not HTTP).

  ## Node name convention

  - Runtime: `ezagent_runtime@<host>` where `<host>` is `127.0.0.1` for
    single-machine dev. Operator can override with `EZAGENT_RUNTIME_NODE` env.
  - CLI: `ezagent_cli_<os_pid>@<host>` (short-lived, unique per invocation).

  ## Cookie

  Stored at `$EZAGENT_HOME/<profile>/runtime/cookie` (chmod 600). Generated
  on first start via `ensure_cookie!/0` if missing.

  Both runtime and CLI read this same file so they share authentication.

  Future: if a remote operator needs to reach this runtime, federation
  protocol (Roadmap §6+) handles runtime↔runtime; CLI itself only ever
  talks to the local runtime per Allen 2026-05-17.
  """

  @default_runtime_host "127.0.0.1"
  @runtime_node_prefix "ezagent_runtime"

  @doc "Absolute path of the runtime cookie file under EZAGENT_HOME."
  def cookie_path do
    Path.join(Ezagent.Home.profile_dir(), "runtime/cookie")
  end

  @doc """
  Read the cookie from disk. Creates one (32-byte hex) if missing.
  Returns an atom (Erlang cookies must be atoms).
  """
  @spec ensure_cookie!() :: atom()
  def ensure_cookie! do
    cookie_str =
      case System.get_env("EZAGENT_COOKIE") do
        s when is_binary(s) and s != "" ->
          # Operator-supplied fixed cookie (docker compose sets EZAGENT_COOKIE).
          # Makes the node's distribution cookie deterministic so `mix ezagent`
          # / `bin/ezagent rpc` (which read EZAGENT_COOKIE / RELEASE_COOKIE)
          # connect out-of-the-box, instead of a random per-boot file cookie
          # (the random one is also URL-base64 and can start with `-`, which
          # breaks `--cookie` arg parsing).
          String.trim(s)

        _ ->
          read_or_generate_cookie_file()
      end

    String.to_atom(cookie_str)
  end

  defp read_or_generate_cookie_file do
    path = cookie_path()

    case File.read(path) do
      {:ok, content} ->
        String.trim(content)

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(path))
        new_cookie = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        File.write!(path, new_cookie)
        File.chmod!(path, 0o600)
        new_cookie
    end
  end

  @doc """
  The runtime node name (atom). Overridable via `EZAGENT_RUNTIME_NODE` env.
  Default `ezagent_runtime@127.0.0.1`.
  """
  @spec runtime_node() :: atom()
  def runtime_node do
    case System.get_env("EZAGENT_RUNTIME_NODE") do
      nil ->
        :"#{@runtime_node_prefix}@#{@default_runtime_host}"

      s when is_binary(s) and s != "" ->
        String.to_atom(s)
    end
  end

  @doc """
  Apply the cookie + start distributed Erlang as the runtime node.
  Called from phx.server boot via `EzagentCore.Application.start/2` so the
  CLI can connect to a known node name with a known cookie.
  """
  def configure_for_runtime! do
    # 2026-06-09 dev 提速:`EZAGENT_NO_DISTRIBUTION=1` 时**完全跳过**分布式 Erlang
    # 启动。本机(WSL)没起 epmd,`:net_kernel.start(.., :longnames)` 会 etimedout
    # 干等数十秒~数分钟,严重拖慢 boot。单机 dev 不需要分布式(分布式只给 CLI
    # `:rpc.call` 连进运行节点用)。默认不开 → 行为不变;开了 → CLI RPC 命令不可用。
    if System.get_env("EZAGENT_NO_DISTRIBUTION") in ["1", "true"] do
      require Logger
      Logger.info("Ezagent.Runtime: distribution skipped (EZAGENT_NO_DISTRIBUTION).")
      :ok
    else
      do_configure_for_runtime!()
    end
  end

  defp do_configure_for_runtime! do
    cookie = ensure_cookie!()
    node_name = runtime_node()

    case :net_kernel.start([node_name, :longnames]) do
      {:ok, _pid} ->
        Node.set_cookie(cookie)
        :ok

      {:error, {:already_started, _}} ->
        # Already up — either previous boot in same VM, or release
        # started it. Just make sure cookie is set.
        Node.set_cookie(cookie)
        :ok

      err ->
        # Allen 2026-05-26: the canonical runtime node name is in
        # use by another OS process. Two contexts hit this:
        #
        # 1. `mix phx.server`: needs the canonical name so CLI
        #    `:rpc.call` can reach in. Failure should be loud — the
        #    operator must resolve (kill the squatter or set a
        #    different EZAGENT_RUNTIME_NODE).
        #
        # 2. Bootstrap mix tasks (e.g. `mix ezagent.user.token
        #    --mint`): don't need distribution at all, just DB.
        #    Falling back to a unique node name is silent + safe.
        #
        # We distinguish via System.argv()[0]: `phx.server` claims
        # canonical or raises; everything else falls back.
        handle_runtime_node_collision(err, cookie)
    end
  end

  # See configure_for_runtime!/0 for the two-context rationale.
  defp handle_runtime_node_collision(err, cookie) do
    case System.argv() do
      ["phx.server" | _] ->
        require Logger

        Logger.error(
          "Ezagent.Runtime: cannot claim #{runtime_node()} — already used by " <>
            "another Erlang node (#{inspect(err)}). phx.server REQUIRES this " <>
            "name for CLI/RPC. Resolve by killing the squatter or setting " <>
            "EZAGENT_RUNTIME_NODE to a different value."
        )

        :ok

      _ ->
        # Bootstrap context: fall back to a unique name silently.
        # The lower-level erlang VM still prints a `[notice]` about
        # the name being in use — that's an erts-level emission we
        # can't suppress without monkey-patching :error_logger.
        fallback =
          :"ezagent_bootstrap_#{System.system_time(:nanosecond)}@#{@default_runtime_host}"

        case :net_kernel.start([fallback, :longnames]) do
          {:ok, _} ->
            Node.set_cookie(cookie)
            :ok

          _ ->
            # Even the fallback failed — surface as a warning but
            # do not crash; bootstrap tasks that don't actually
            # touch distribution will still complete.
            require Logger

            Logger.warning(
              "Ezagent.Runtime: net_kernel start failed for both canonical and " <>
                "fallback names; distribution unavailable. Original error: " <>
                "#{inspect(err)}"
            )

            :ok
        end
    end
  end

  @doc """
  CLI-side: start the CLI's own distributed node + connect to the
  runtime. Returns `{:ok, runtime_node}` if connection succeeds,
  `{:error, :runtime_not_reachable}` otherwise.

  CLI's own node name includes os_pid so multiple concurrent CLI
  invocations don't collide.
  """
  def connect_as_cli do
    cookie = ensure_cookie!()
    runtime = runtime_node()
    cli_node = :"ezagent_cli_#{System.system_time(:nanosecond)}@127.0.0.1"

    case :net_kernel.start([cli_node, :longnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      err -> {:error, {:cli_node_start_failed, err}}
    end
    |> case do
      :ok ->
        Node.set_cookie(cookie)

        if Node.connect(runtime) == true do
          {:ok, runtime}
        else
          {:error, :runtime_not_reachable}
        end

      err ->
        err
    end
  end
end

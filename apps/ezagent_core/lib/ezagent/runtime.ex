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
    path = cookie_path()

    cookie_str =
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

    String.to_atom(cookie_str)
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
        # use by another OS process (typically: yao.shengyue's
        # 12-day-old phx, or a parallel local dev BEAM, or any
        # bootstrap mix task firing alongside a running phx). For
        # phx.server itself this would be fatal — but for bootstrap
        # mix tasks (e.g. `mix ezagent.user.token --mint` writing
        # directly to the DB) distribution is incidental.
        #
        # Fall back to a unique distinguishing name so the BEAM has
        # SOME node identity (Phoenix.PubSub etc. care that the
        # node is alive even when not federated). The fallback name
        # is per-OS-process so concurrent bootstrap invocations
        # don't trample each other.
        fallback =
          :"ezagent_bootstrap_#{System.system_time(:nanosecond)}@#{@default_runtime_host}"

        case :net_kernel.start([fallback, :longnames]) do
          {:ok, _} ->
            Node.set_cookie(cookie)
            :ok

          _ ->
            require Logger

            Logger.warning(
              "Ezagent.Runtime: net_kernel start failed (#{inspect(err)}); CLI will fall back to error path"
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

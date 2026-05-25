defmodule Mix.Tasks.Esr do
  @shortdoc "CLI shell — connects via distributed Erlang to the running ESR runtime"
  @moduledoc """
  Post-Phase-5 second pivot (Allen 2026-05-17): `mix esr` is a thin
  shell that connects to the running ESR runtime via distributed
  Erlang RPC. The actual `EzagentCli.Exec.exec/1` runs INSIDE the
  runtime BEAM — same process tree as LV, same KindRegistry,
  same Repo, same audit telemetry. Restores CLI ↔ LV runtime
  isomorphism without any HTTP serde indirection.

  ## Usage

      mix esr <kind> <action> [--<arg>=<val> ...]
      mix esr --help
      mix esr help <subcommand>

  ## Environment

      EZAGENT_RUNTIME_NODE   Node name to reach (default ezagent_runtime@127.0.0.1)
      EZAGENT_HOME           Where the runtime cookie file lives
                         (default ~/.ezagent)
      EZAGENT_USER_TOKEN     Bearer token (verified via `entity_tokens`)
      EZAGENT_ENTITY_URI     Entity URI the token belongs to (e.g.
                             `entity://user/system/admin` or `entity://agent/team-alpha/cc_demo`)

  ## Single-machine assumption

  Per Allen's directive: CLI only ever talks to a LOCAL runtime. For
  remote operations, runtime-to-runtime federation (Roadmap §6+) handles
  the cross-machine case; CLI itself stays single-machine.

  If the runtime isn't running, prints a clear error.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # PR #142: bearer tokens are now entity-agnostic (entity_tokens
    # table). The CLI presents BOTH the token and the entity URI it
    # was minted for (verify is keyed by URI). Token-less calls fall
    # back to admin caps (single-user BC).
    {token, argv} = extract_token(argv)
    {entity_uri, argv} = extract_entity_uri(argv)

    case Ezagent.Runtime.connect_as_cli() do
      {:ok, runtime_node} ->
        case :rpc.call(
               runtime_node,
               EzagentCli.Exec,
               :exec,
               [argv, [token: token, entity_uri: entity_uri]],
               30_000
             ) do
          %{output: output, exit_code: code} ->
            IO.write(output)
            exit_with(code)

          {:badrpc, reason} ->
            IO.puts(:stderr, "error: rpc failed: #{inspect(reason)}")
            exit_with(1)
        end

      {:error, :runtime_not_reachable} ->
        IO.puts(
          :stderr,
          "error: ESR runtime not reachable at #{Ezagent.Runtime.runtime_node()}\n" <>
            "       start it with `mix phx.server` (single-machine assumption)\n" <>
            "       or set EZAGENT_RUNTIME_NODE to point at a running instance"
        )

        exit_with(5)

      {:error, reason} ->
        IO.puts(:stderr, "error: #{inspect(reason)}")
        exit_with(1)
    end
  end

  # Pluck --token=VAL or --token VAL out of argv; falls back to EZAGENT_USER_TOKEN.
  defp extract_token(argv) do
    {tok, rest} = pluck_flag(argv, "--token", [])
    {tok || System.get_env("EZAGENT_USER_TOKEN"), rest}
  end

  # Pluck --uri=VAL / --uri VAL out of argv; falls back to EZAGENT_ENTITY_URI.
  defp extract_entity_uri(argv) do
    {uri, rest} = pluck_flag(argv, "--uri", [])
    {uri || System.get_env("EZAGENT_ENTITY_URI"), rest}
  end

  defp pluck_flag([], _name, acc), do: {nil, Enum.reverse(acc)}

  defp pluck_flag([head | tail], name, acc) do
    eq_form = name <> "="

    cond do
      String.starts_with?(head, eq_form) ->
        v = String.replace_prefix(head, eq_form, "")
        {v, Enum.reverse(acc) ++ tail}

      head == name ->
        case tail do
          [v | rest] -> {v, Enum.reverse(acc) ++ rest}
          [] -> {nil, Enum.reverse(acc)}
        end

      true ->
        pluck_flag(tail, name, [head | acc])
    end
  end

  defp exit_with(code) when is_integer(code) do
    if Mix.env() == :test do
      throw({:cli_exit, code})
    else
      System.halt(code)
    end
  end
end

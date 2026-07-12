defmodule Mix.Tasks.Ezagent do
  @shortdoc "CLI shell — connects via distributed Erlang to the running ezagent runtime"
  @moduledoc """
  Post-Phase-5 second pivot (Allen 2026-05-17): `mix ezagent` is a thin
  shell that connects to the running ezagent runtime via distributed
  Erlang RPC. The actual `EzagentCli.Exec.exec/1` runs INSIDE the
  runtime BEAM — same process tree as LV, same KindRegistry,
  same Repo, same audit telemetry. Restores CLI ↔ LV runtime
  isomorphism without any HTTP serde indirection.

  ## Usage

      mix ezagent <kind> <action> [--<arg>=<val> ...]
      mix ezagent --help
      mix ezagent help <subcommand>

  Renamed from `mix esr` 2026-05-26 (Allen) — the PR #114 mega-rename
  ESR→Ezagent missed the CLI module name. `Mix.Tasks.Esr` still
  resolves as a thin backwards-compat alias that delegates here +
  prints a one-line deprecation notice; it will be removed when
  operator muscle memory has had time to migrate.

  ## Environment

      EZAGENT_RUNTIME_NODE   Node name to reach (default ezagent_runtime@127.0.0.1)
      EZAGENT_HOME           Where the runtime cookie file lives
                         (default ~/.ezagent)
      EZAGENT_USER_TOKEN     Bearer token (verified via `entity_tokens`)

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
    # table). The token itself selects the digest version and resolves
    # directly to its principal; no identity URI is accepted.
    {token, argv} = extract_token(argv)

    case Ezagent.Runtime.connect_as_cli() do
      {:ok, runtime_node} ->
        case :rpc.call(
               runtime_node,
               EzagentCli.Exec,
               :exec,
               [argv, [token: token]],
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
          "error: ezagent runtime not reachable at #{Ezagent.Runtime.runtime_node()}\n" <>
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

defmodule Mix.Tasks.Esr do
  @shortdoc "DEPRECATED — use `mix ezagent` (renamed 2026-05-26)"
  @moduledoc """
  Backwards-compat alias for the renamed `mix ezagent` CLI shell.

  Allen 2026-05-26: the project was rebranded ESR → Ezagent in PR #114,
  but the CLI module name (`Mix.Tasks.Esr` → command `mix esr`) was
  missed. Renamed canonically to `Mix.Tasks.Ezagent` (command
  `mix ezagent`). This module remains as a thin delegate so operator
  muscle memory + existing scripts that type `mix esr ...` continue
  to work; it prints a one-line deprecation hint to stderr so the
  rename surfaces.

  This module will be removed in a future release once operator
  muscle memory has had time to migrate. Update any scripts /
  documentation that reference `mix esr` to `mix ezagent`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    IO.puts(
      :stderr,
      "NOTE: `mix esr` is renamed to `mix ezagent` (2026-05-26). " <>
        "This alias still works but will be removed in a future release."
    )

    Mix.Tasks.Ezagent.run(argv)
  end
end

defmodule EzagentCli.Exec do
  @moduledoc """
  Server-side CLI executor — Allen 2026-05-17 pivots.

  Called via distributed Erlang RPC from `Mix.Tasks.Esr` on the CLI
  side: `:rpc.call(ezagent_runtime@127.0.0.1, EzagentCli.Exec, :exec, [argv])`.
  Runs in the SAME BEAM as LV — same KindRegistry, same ETS tables,
  same Repo connections. No HTTP indirection, no separate VM.

      mix ezagent --(argv)→  :rpc.call → EzagentCli.Exec.exec/1
                                       ↓
                                [parse + Coerce + Invocation +
                                 dispatch — all in running BEAM]
                                       ↓
                       %{output, exit_code} (Elixir map, native term)
                                       ↓
      print + exit

  ## Return

  `%{output: String.t(), exit_code: 0..5}` — `output` is the
  rendered formatter result (text or JSON, depending on --json flag);
  `exit_code` follows EzagentCli.Formatter conventions.
  """

  alias EzagentCli.{Dispatch, Formatter, TreeBuilder}

  @spec exec([String.t()]) :: %{output: String.t(), exit_code: integer()}
  def exec(argv) when is_list(argv), do: exec(argv, [])

  @doc """
  PR #142: 2-arg form accepts CLI-level options. Currently:

    * `:token` — bearer token resolved directly to its principal.

  Codex CLI/GUI audit 2026-05-24 HIGH-1 (`feedback_let_it_crash_no_workarounds`):
  the previous code fell back to admin caps when no token was
  supplied ("BC for single-user installs"). That's a silent
  privilege elevation: anyone reaching this entry point with no
  credentials ran as admin. CLOSED — no token now means refuse.
  """
  @spec exec([String.t()], keyword()) :: %{output: String.t(), exit_code: integer()}
  def exec(argv, opts) when is_list(argv) and is_list(opts) do
    # Codex CLI/GUI audit HIGH-1 — help / version / no-args paths
    # bypass auth (they don't dispatch any action). All real argv
    # require a token.
    if help_only_argv?(argv) do
      do_exec(argv)
    else
      exec_with_auth(argv, opts)
    end
  end

  # Argv that don't need authentication — help / version / no-args
  # commands surface usage info without dispatching anything.
  defp help_only_argv?([]), do: true
  defp help_only_argv?(["--help" | _]), do: true
  defp help_only_argv?(["-h" | _]), do: true
  defp help_only_argv?(["--version" | _]), do: true
  defp help_only_argv?(_), do: false

  defp exec_with_auth(argv, opts) do
    case resolve_caller(opts[:token]) do
      {:ok, caller_uri, caller_caps} ->
        # Store on the per-call process dict so Dispatch.derive_caller
        # (in the same RPC-handling pid) picks it up without threading
        # opts through every command.
        Process.put(:ezagent_cli_caller_override, {caller_uri, caller_caps})

        try do
          do_exec(argv)
        after
          Process.delete(:ezagent_cli_caller_override)
        end

      {:error, :no_token} ->
        %{
          output:
            "error: CLI calls require authentication. Pass --token\n" <>
              "       (or set EZAGENT_USER_TOKEN). Mint a\n" <>
              "       token with `mix ezagent.user.token mint <entity-uri>`.\n",
          exit_code: 4
        }

      {:error, :invalid_token} ->
        %{output: "error: invalid or revoked CLI token\n", exit_code: 4}
    end
  end

  defp do_exec(argv) do
    spec = TreeBuilder.build()

    case Optimus.parse(spec, argv) do
      {:ok, _parsed_top_no_subcommand} ->
        %{output: Optimus.help(spec), exit_code: 0}

      {:ok, subcommand_path, parsed} ->
        handle_subcommand(subcommand_path, parsed, spec)

      {:error, _subcommand_path, errors} ->
        %{output: format_errors(errors), exit_code: 2}

      {:error, errors} when is_list(errors) ->
        %{output: format_errors(errors), exit_code: 2}

      :help ->
        %{output: Optimus.help(spec), exit_code: 0}

      {:help, subcommand_path} ->
        sub_spec = Optimus.fetch_subcommand(spec, subcommand_path)
        # Single-segment path (e.g. `mix ezagent help agent`) lands
        # on a subcommand with further subcommand children — use our
        # custom formatter to dodge the Optimus `:badmap` crash (see
        # `format_subcommand_help/1`). Deeper paths (action-level)
        # have no children and Optimus.help/1 works.
        output =
          case subcommand_path do
            [_kind] -> format_subcommand_help(sub_spec)
            _ -> Optimus.help(sub_spec)
          end

        %{output: output, exit_code: 0}

      :version ->
        %{output: "esr 0.1.0", exit_code: 0}
    end
  end

  # Codex CLI/GUI audit HIGH-1: nil/empty token = no authentication =
  # REFUSE. Previously this returned {:ok, nil, nil} which Dispatch
  # then turned into admin caps (the silent fallback path). Now we
  # surface `:no_token` so Exec returns a clear exit-4 error.
  defp resolve_caller(nil), do: {:error, :no_token}
  defp resolve_caller(""), do: {:error, :no_token}

  defp resolve_caller(token) when is_binary(token) do
    case Ezagent.Authentication.authenticate(token) do
      {:ok, uri} -> {:ok, uri, uri |> Ezagent.Identity.read_entity_caps() |> MapSet.new()}
      {:error, _} -> {:error, :invalid_token}
    end
  end

  defp handle_subcommand([kind_atom], _parsed, spec) do
    sub = Optimus.fetch_subcommand(spec, [kind_atom])
    %{output: format_subcommand_help(sub), exit_code: 0}
  end

  defp handle_subcommand([kind_atom, action_atom], parsed, _spec) do
    result =
      case find_behavior_for(kind_atom, action_atom) do
        {:ok, kind_module, behavior_module} ->
          Dispatch.run_action(kind_module, behavior_module, action_atom, parsed)

        :error ->
          Dispatch.run_facade(kind_atom, action_atom, parsed)
      end

    json? = Map.get(parsed.flags, :json, false)
    {output, exit_code} = Formatter.render(result, json?)
    %{output: output, exit_code: exit_code}
  end

  defp handle_subcommand(other, _parsed, _spec) do
    %{output: "error: unknown subcommand path: #{inspect(other)}", exit_code: 2}
  end

  # Allen 2026-05-26: `Optimus.help/1` on a fetched subcommand whose
  # children are themselves Optimus structs (`mix ezagent agent` →
  # children are `put_api_key`, `get_api_key`, ...) raises a
  # `:badmap` in Optimus's internal help formatter. The formatter
  # expects `subcommands` to be a keyword list `[{name, t()}, ...]`
  # but `Optimus.new!/1` normalizes them to bare structs at the
  # outer level — fetch_subcommand preserves the bare-struct shape
  # and the formatter explodes on the first pattern-match.
  #
  # Rather than patching the upstream library, we render a minimal
  # but operator-useful help block ourselves: USAGE + the list of
  # available actions with their `about` line. Detail per action
  # (flags / options) is available via `mix ezagent <kind> <action>
  # --help` — Optimus.help/1 works fine when the spec has no
  # further subcommand children.
  # `Optimus.fetch_subcommand/2` returns a 2-tuple `{%Optimus{},
  # name_path_reversed}` — NOT a bare struct. Unwrap before
  # formatting. (This shape was the root of the `Optimus.help/1`
  # `:badmap` crash: the help formatter pattern-matched on the
  # struct fields and got the tuple instead.)
  defp format_subcommand_help({%Optimus{} = sub, name_path})
       when is_list(name_path) do
    # `Optimus.fetch_subcommand/2` returns `name_path` already
    # in top-to-bottom order (root first). Drop the top-level
    # name (legacy `esr` — the CLI is invoked as `mix ezagent`,
    # PR #386 renamed the Mix task but the Optimus root name was
    # not updated; fix that separately).
    full_name =
      case name_path do
        [_root | rest] -> Enum.join(["mix ezagent" | rest], " ")
        [] -> "mix ezagent #{sub.name}"
      end

    do_format_subcommand_help(sub, full_name)
  end

  defp format_subcommand_help(%Optimus{} = sub) do
    do_format_subcommand_help(sub, sub.name)
  end

  defp format_subcommand_help(other) do
    # Defensive — should never hit; if it does, fall back to the
    # raw struct so the operator at least sees something.
    inspect(other, pretty: true)
  end

  defp do_format_subcommand_help(%Optimus{about: about, subcommands: subs}, full_name) do
    actions =
      subs
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn s ->
        "    #{String.pad_trailing(s.name, 22)} #{s.about || ""}"
      end)
      |> Enum.join("\n")

    """

                                      #{full_name}

    #{about || ""}

    USAGE:

        #{full_name} <action> [--<option>=<value> ...]
        #{full_name} <action> --help

    ACTIONS:

    #{actions}

    """
  end

  defp find_behavior_for(kind_atom, action_atom) do
    triples = Ezagent.BehaviorRegistry.list_all()

    Enum.find_value(triples, :error, fn {{kind_module, action}, behavior_module} ->
      # Defensive: skip test-leaked fake modules — same pattern as
      # EzagentCli.TreeBuilder.safe_type_name/1. Without this, an
      # umbrella-test-leaked FakeK in BehaviorRegistry crashes the
      # CLI server-side path.
      case safe_type_name(kind_module) do
        nil ->
          nil

        ^kind_atom when action == action_atom ->
          {:ok, kind_module, behavior_module}

        _ ->
          nil
      end
    end)
  end

  defp safe_type_name(kind_mod) do
    if Code.ensure_loaded?(kind_mod) and function_exported?(kind_mod, :type_name, 0) do
      try do
        kind_mod.type_name()
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
    else
      nil
    end
  end

  defp format_errors(errors), do: Enum.map_join(errors, "\n", &("error: " <> &1))
end

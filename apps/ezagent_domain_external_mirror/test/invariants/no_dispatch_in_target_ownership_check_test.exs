defmodule Ezagent.ExternalMirror.Invariants.NoDispatchInTargetOwnershipCheckTest do
  @moduledoc """
  PR-EM-FINAL invariant from SPEC §10 (g) — round-3 MEDIUM fix.

  > **No `Ezagent.Invocation.dispatch` (or `Kind.spawn` /
  > `Behavior.invoke` direct) from inside any adapter module's
  > `target_ownership_check/2` callback.** Grep gate against all
  > modules declared as adapters in any plugin's `adapters/0`.
  > Catches an adapter author who tries to re-enter ezagent from
  > inside the bind-time check — would cause dispatch-during-dispatch
  > deadlock since `:bind` is itself a dispatched action.

  ## Why this matters

  `target_ownership_check/2` runs inside a `Task.Supervisor.async_nolink/3`
  spawned by the facade — but the FACADE itself was called from inside
  a dispatched `:bind` action body (at least via the action path), and
  more importantly the caller is typically holding an
  `Invocation.dispatch/1` call open. Re-entering dispatch from inside
  the Task can:

  - Deadlock on a Kind.Server `GenServer.call` reaching a process
    upstream that's waiting on us.
  - Trigger the `Phoenix.PubSub` consumer fan-out path that
    `Ezagent.Notifications` uses, which would re-trigger SliceChange
    delivery from a transient process.

  Adapters MUST NOT make this category of call. The contract is
  documented in `Ezagent.ExternalMirror.Adapter`'s `target_ownership_check/2`
  callback @doc.

  ## Strategy — runtime-attribute discovery + source-file grep

  Three phases (codex r2 P2 fix — discovery now uses compiled module
  attributes, not source-text regex, so aliased declarations like
  `alias Ezagent.ExternalMirror.Adapter` + `@behaviour Adapter` are
  caught):

  1. Walk `:code.all_loaded/0` and filter modules whose
     `module_info(:attributes)[:behaviour]` contains
     `Ezagent.ExternalMirror.Adapter`. Elixir resolves both spellings
     to the same compile-time attribute value.
  2. Resolve each module's source path via
     `:beam_lib.chunks(beam_path, [:compile_info])[:source]` (the
     absolute path the compiler recorded). Avoids the `:code.which/1`
     → snake-case-path fragility codex r1 P1 caught.
  3. Grep each source file for the forbidden patterns. Patterns match
     BOTH fully-qualified AND aliased forms
     (`(?:Ezagent\.)?Invocation\.dispatch\(`, etc) — codex r2 P2.

  ## False-positive control

  A few adapter modules legitimately reference these symbols in
  moduledoc / @doc heredocs explaining what NOT to do. The
  `comment_or_docstring?/1` filter handles those (matches both
  fully-qualified AND aliased prose forms) — same heuristic the
  `single_spawn_entry_test.exs` invariant uses.
  """
  use ExUnit.Case, async: true

  # Codex r2 P2 fix: match BOTH fully-qualified AND aliased
  # spellings. `alias Ezagent.Invocation` + `Invocation.dispatch(`
  # is valid Elixir + causes the same dispatch-during-dispatch
  # deadlock; the gate now catches both.
  @forbidden_patterns [
    "(?:Ezagent\\.)?Invocation\\.dispatch\\(",
    "(?:Ezagent\\.)?Kind\\.spawn\\(",
    "(?:Ezagent\\.)?Behavior\\.invoke\\("
  ]

  test "no adapter source file calls Ezagent.Invocation.dispatch / Kind.spawn / Behavior.invoke" do
    # Source-level scan: grep every `.ex` under `apps/` for the
    # `@behaviour Ezagent.ExternalMirror.Adapter` declaration; those
    # files ARE the adapter sources. Then grep those files for the
    # forbidden patterns.
    #
    # Source-level @behaviour grep avoids the `:code.which/1` →
    # snake-case-path mapping fragility codex r1 P1 caught (the prior
    # implementation derived `apps/<app>/lib/Elixir.Some.Mod.ex` from
    # `_build/.../Elixir.Some.Mod.beam` — that path NEVER exists since
    # real source paths are snake_case + nested directories).

    adapter_source_files = find_adapter_source_files()

    violations =
      adapter_source_files
      |> Enum.flat_map(&scan_file/1)

    assert violations == [],
           """
           Adapter source file(s) re-enter ezagent dispatch — violates
           SPEC §10 (g) / PR-EM-FINAL invariant.

           `target_ownership_check/2` runs inside the facade's Task; a
           call to `Ezagent.Invocation.dispatch/1` (or `Kind.spawn` /
           `Behavior.invoke` direct) would create a dispatch-during-
           dispatch deadlock because `:bind` is itself a dispatched
           action. Even if the call is in `event_to_payload/1` (which
           runs inside the Worker), re-entering dispatch from there
           creates the same hazard plus blocks the per-binding scheduler
           quantum.

           Adapters are STATELESS pure functions per SPEC §2.2.
           External API calls (Lark/Slack/etc) belong in the Binding
           module (`publish/2` callback). The ONE exception is
           `target_ownership_check/2` which MAY call external APIs
           directly but MUST NOT re-enter ezagent.

           Offenders:
           #{Enum.join(violations, "\n")}

           Adapter source files scanned:
           #{Enum.join(adapter_source_files, "\n")}
           """
  end

  # Find every source file owning a module that declares
  # `@behaviour Ezagent.ExternalMirror.Adapter` — spelled-out OR
  # aliased (`alias Ezagent.ExternalMirror.Adapter` + `@behaviour Adapter`).
  # Walks EVERY beam under every umbrella app's ebin (not just
  # `:code.all_loaded/0` — modules are loaded lazily, so a fresh
  # ExUnit process wouldn't see plugin adapters not yet referenced
  # at boot), then filters via the loaded module's behaviour
  # attribute + source via `:beam_lib.chunks/2`.
  defp find_adapter_source_files do
    all_beams()
    |> Enum.map(&module_from_beam/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&ensure_loaded/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&adapter_behaviour?/1)
    |> Enum.flat_map(&source_for_module/1)
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.uniq()
  end

  # Enumerate every `.beam` under `_build/<env>/lib/<app>/ebin/` for
  # every umbrella app. This + `Code.ensure_loaded/1` is the way to
  # cover lazily-loaded plugin modules that no other test would have
  # touched yet. Adds each app's ebin to the BEAM code path so
  # `Code.ensure_loaded/1` finds modules from apps NOT in this app's
  # mix.exs deps (e.g. plugin Adapters in sibling apps).
  defp all_beams do
    build_dir = Path.join([umbrella_root(), "_build", to_string(Mix.env()), "lib"])

    case File.ls(build_dir) do
      {:ok, apps} ->
        Enum.flat_map(apps, fn app ->
          ebin = Path.join([build_dir, app, "ebin"])
          :code.add_pathz(String.to_charlist(ebin))

          case File.ls(ebin) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.ends_with?(&1, ".beam"))
              |> Enum.map(&Path.join(ebin, &1))

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp module_from_beam(beam_path) do
    base =
      beam_path
      |> Path.basename(".beam")
      |> String.replace_prefix("Elixir.", "")

    String.to_atom("Elixir." <> base)
  rescue
    _ -> nil
  end

  defp ensure_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> module
      _ -> nil
    end
  end

  defp umbrella_root do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {top, 0} ->
          top

        _ ->
          # No .git inside the release image (#21 docker) — resolve the
          # umbrella root from cwd (umbrella root or the app under test).
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end
    String.trim(out)
  end

  defp adapter_behaviour?(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(Ezagent.ExternalMirror.Adapter)
  rescue
    _ -> false
  end

  defp source_for_module(module) do
    with beam_path when is_list(beam_path) <- :code.which(module),
         {:ok, {_, [{:compile_info, info}]}} <-
           :beam_lib.chunks(beam_path, [:compile_info]),
         source when is_list(source) <- Keyword.get(info, :source) do
      [List.to_string(source)]
    else
      _ -> []
    end
  end

  defp scan_file(file) do
    Enum.flat_map(@forbidden_patterns, fn pattern ->
      {output, grep_exit} =
        System.cmd(
          "grep",
          ["-En", pattern, file],
          stderr_to_stdout: false
        )

      # grep exit 0 = matches, 1 = clean (no matches); ≥2 = scan error. Fail
      # loud rather than silently passing the gate on an empty result.
      if grep_exit > 1, do: raise("grep scan failed (exit #{grep_exit}) for #{file}")

      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> "#{file}:#{line}" end)
      |> Enum.reject(&comment_or_docstring?/1)
    end)
  end

  # `grep -n` output is `<lineno>:<body>` on the per-file form; the
  # `scan_file/1` prefixer makes it `<file>:<lineno>:<body>` (3 parts).
  defp comment_or_docstring?(line) do
    case String.split(line, ":", parts: 3) do
      [_file, _lineno, body] ->
        trimmed = String.trim_leading(body)

        cond do
          String.starts_with?(trimmed, "#") -> true
          prose_reference?(body) -> true
          true -> false
        end

      _ ->
        false
    end
  end

  # Codex r2 P2: the forbidden patterns now match both fully-qualified
  # AND aliased forms, so the prose filter must also accept both.
  defp prose_reference?(body) do
    Enum.any?(
      [
        "`Ezagent.Invocation.dispatch",
        "`Invocation.dispatch",
        "`Ezagent.Kind.spawn",
        "`Kind.spawn",
        "`Ezagent.ActionSet.invoke",
        "`Behavior.invoke"
      ],
      &String.contains?(body, &1)
    )
  end

end

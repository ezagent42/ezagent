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

  ## Strategy — scan binding/adapter source files for forbidden calls

  The grep walks every loaded Adapter module's source file (`:code.which/1`
  → source path map) and looks for the forbidden patterns. The scope is
  narrowed to the `def target_ownership_check` callback body, but in
  practice a simpler whole-file scan is sufficient because adapter
  modules are tiny pure-function modules — any `Ezagent.Invocation.dispatch`
  in an adapter module is suspicious regardless of which callback it
  lives in.

  ## False-positive control

  A few adapter modules legitimately reference these symbols in
  moduledoc / @doc heredocs explaining what NOT to do. The
  `comment_or_docstring?/1` filter handles those — same heuristic the
  `single_spawn_entry_test.exs` invariant uses.
  """
  use ExUnit.Case, async: true

  @forbidden_patterns [
    "Ezagent\\.Invocation\\.dispatch\\(",
    "Ezagent\\.Kind\\.spawn\\(",
    "Behavior\\.invoke\\("
  ]

  test "no adapter module calls Ezagent.Invocation.dispatch / Kind.spawn / Behavior.invoke in its source" do
    adapter_modules =
      :code.all_loaded()
      |> Enum.map(fn {mod, _file} -> mod end)
      |> Enum.filter(&adapter_behaviour?/1)

    violations =
      adapter_modules
      |> Enum.flat_map(&source_files_for_module/1)
      |> Enum.uniq()
      |> Enum.flat_map(&scan_file/1)

    assert violations == [],
           """
           Adapter module(s) re-enter ezagent dispatch — violates
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

           Adapters checked: #{inspect(adapter_modules)}
           """
  end

  defp adapter_behaviour?(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Ezagent.ExternalMirror.Adapter in behaviours
  rescue
    _ -> false
  end

  defp source_files_for_module(module) do
    case :code.which(module) do
      beam_path when is_list(beam_path) ->
        beam_str = List.to_string(beam_path)

        candidates =
          [
            beam_str
            |> String.replace(~r{/_build/.*?/lib/(.+?)/ebin/}, "/apps/\\1/lib/")
            |> String.replace(~r{\.beam$}, ".ex")
          ]

        Enum.filter(candidates, &File.exists?/1)

      _ ->
        []
    end
  end

  defp scan_file(file) do
    Enum.flat_map(@forbidden_patterns, fn pattern ->
      {output, _exit} =
        System.cmd(
          "grep",
          ["-En", pattern, file],
          stderr_to_stdout: true
        )

      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> "#{file}:#{line}" end)
      |> Enum.reject(&comment_or_docstring?/1)
    end)
  end

  defp comment_or_docstring?(line) do
    case String.split(line, ":", parts: 4) do
      [_path, _path2, _lineno, body] ->
        trimmed = String.trim_leading(body)

        cond do
          String.starts_with?(trimmed, "#") -> true
          prose_reference?(body) -> true
          true -> false
        end

      [_path, _lineno, body] ->
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

  defp prose_reference?(body) do
    String.contains?(body, "`Ezagent.Invocation.dispatch") or
      String.contains?(body, "`Ezagent.Kind.spawn") or
      String.contains?(body, "`Behavior.invoke")
  end
end

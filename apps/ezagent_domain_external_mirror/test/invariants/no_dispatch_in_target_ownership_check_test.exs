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

  # Find every `.ex` file in `apps/` that has an ACTUAL
  # `@behaviour Ezagent.ExternalMirror.Adapter` declaration at the
  # start of a line (module-level attribute) — NOT a comment / heredoc
  # mention inside something like `ezagent_plugin_check.ex` or
  # `binding.ex`'s contract doc.
  defp find_adapter_source_files do
    {output, _exit} =
      System.cmd(
        "grep",
        [
          "-rEl",
          "^\\s*@behaviour\\s+Ezagent\\.ExternalMirror\\.Adapter\\b",
          apps_root(),
          "--include=*.ex"
        ],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.uniq()
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

  defp prose_reference?(body) do
    String.contains?(body, "`Ezagent.Invocation.dispatch") or
      String.contains?(body, "`Ezagent.Kind.spawn") or
      String.contains?(body, "`Behavior.invoke")
  end

  defp apps_root do
    {out, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    Path.join(String.trim(out), "apps")
  end
end

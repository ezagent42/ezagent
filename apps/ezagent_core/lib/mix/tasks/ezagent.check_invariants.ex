defmodule Mix.Tasks.Ezagent.CheckInvariants do
  @shortdoc "Check Ezagent's 8 hard invariants — Phase 1 step-3 active"

  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (dev-loop tool).**
  > Intentionally NOT a dispatched op. Source-tree grep that runs
  > without the runtime BEAM. Stays as `mix ezagent.*`; do NOT
  > migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Bootstrap row) + Finding 2 carve-out.

  Greps the codebase for violations of Ezagent's 8 hard invariants
  (ARCHITECTURE.md Decision Log / GLOSSARY.md / VERIFICATION.md
  §不变式 grep 完整命令清单).

  ## Progressive coverage

  Each Phase 1 step extends this task with the invariants that become
  meaningfully checkable once the relevant code lands:

  - **Phase 0**: no-op (no dispatch path)
  - Step 1: invariant **#4 put_new for unique-key**
  - Step 2: adds **#2** (use Ezagent.Kind lifecycle) and **#3**
    (`:not_ready + :call` fail-fast)
  - **Step 3** (this commit): adds **#1** (inbound via dispatch —
    `PubSub.broadcast` allowlist: only `:events` topics and
    `esr:audit:stream` may broadcast), **#6** (audit async — no
    direct SQL in `audit.ex`), and **#7** (zero-match → DLQ)
  - **Phase 3d**: adds **#9** (`:stub_grant` atom no longer appears
    in runtime code — hard flip enforcement) and **#10** (Capability
    .matches? is grep-present in dispatch step 5.5; runtime invariant
    test in runtime_phase3d_test.exs is the real cap-deny gate)
  - Phase 5+ will add **#5** (snapshot on slice change) and **#8**
    (CC channel via stdio)

  ## Exit semantics

  Exit `0` = all in-scope invariants pass.
  Exit non-zero = at least one violation; stderr contains the failing
  grep output and the invariant number.

  Invoked by the sub-step gate (`scripts/hooks/sub-step-gate.sh`) and
  available standalone as `mix ezagent.check_invariants`.
  """
  use Mix.Task

  @repo_root Path.expand("../../../../..", __DIR__)

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("ezagent.check_invariants — Phase 1 step 3 active")

    failures =
      [
        check_invariant_1(),
        check_invariant_2(),
        check_invariant_3(),
        check_invariant_4(),
        check_invariant_6(),
        check_invariant_7(),
        check_invariant_9(),
        check_invariant_10(),
        check_comms_participation_profile_gate(),
        check_web_external_mirror_ioc_gate()
      ]
      |> Enum.reject(&match?(:ok, &1))

    if failures == [] do
      Mix.shell().info("  ✓ all in-scope invariants clean")
      :ok
    else
      Enum.each(failures, fn {:error, num, output} ->
        Mix.shell().error("  ✗ invariant ##{num} VIOLATION:")
        Mix.shell().error(output)
      end)

      Mix.raise("ezagent.check_invariants: #{length(failures)} invariant(s) violated")
    end
  end

  # Invariant #1: inbound via dispatch (no bare PubSub.broadcast)
  # `Phoenix.PubSub.broadcast` is legitimate for:
  # - `:events` topics (view fan-out per §5.7.6)
  # - `esr:audit:stream` (audit view fan-out, this is `Ezagent.Audit`)
  # - Chat outbound broadcasts (session/user :events topics) inside
  #   `Ezagent.ActionSet.Session` — these are view fan-out per §5.7.6, same
  #   shape as audit.ex; the inbound path is the dispatch that
  #   triggered `invoke/4` in the first place.
  # Any other broadcast call would be an inbound-message path which
  # MUST go through `Ezagent.Invocation.dispatch/1` instead (event 2.1
  # root cause).
  defp check_invariant_1 do
    # Allowlisted files for PubSub.broadcast:
    # - `audit.ex`: legitimate view fan-out to esr:audit:stream (§5.7.6)
    # - `invocation.ex`: reply path :phoenix_pubsub (caller chose this
    #   reply target explicitly — not an inbound message broadcast)
    # - `kind/runtime/effects.ex`: Kind.Runtime `:notify` effect fan-out
    #   (the dispatch path already entered Runtime; this is not an inbound
    #   message broadcast)
    # - `behavior/chat.ex`: session/user :events fan-out from Chat.invoke
    #   (Phase 2b-step 2 — fan-out to LV stream subscribers, NOT an
    #   inbound message; inbound side is the dispatch that fired invoke)
    # - domain PTY/Python/AgentBridge/Socialware modules: runtime status,
    #   stream, auth, connection, and customer-feed fan-out. These are
    #   observer notifications, not inbound command dispatch.
    #   (2026-07-13: `auth_observers.ex` / `phase_broadcast.ex` carry PTY
    #   fan-out extracted verbatim from `server.ex` to keep that module under
    #   the oversized-module gate. Same category: operator-visibility fan-out,
    #   never an inbound message.)
    # Plus the standard exclusions (tests, this checker).
    {output, _exit_code} =
      System.cmd(
        "bash",
        [
          "-c",
          # Strip lines that are pure prose mentions (backtick-quoted
          # symbol inside docstring) rather than actual code calls.
          "grep -rnE 'PubSub\\.broadcast' apps 2>/dev/null --include='*.ex' " <>
            "| grep -v '/test/' " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/audit.ex' " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/invocation.ex' " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/kind/runtime.ex' " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/kind/runtime/effects.ex' " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/slice_change.ex' " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/cc_events.ex' " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/publisher_lifecycle.ex' " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/notifications.ex' " <>
            "| grep -v 'apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex' " <>
            "| grep -v 'apps/ezagent_domain_pty/lib/ezagent_domain_pty/parked_dialog_watch.ex' " <>
            "| grep -v 'apps/ezagent_domain_pty/lib/ezagent_domain_pty/auth_observers.ex' " <>
            "| grep -v 'apps/ezagent_domain_pty/lib/ezagent_domain_pty/phase_broadcast.ex' " <>
            "| grep -v 'apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex' " <>
            "| grep -v 'apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/registry.ex' " <>
            "| grep -v 'apps/ezagent_domain_session/lib/ezagent/socialware/settlement.ex' " <>
            "| grep -v 'apps/ezagent_domain_session/lib/ezagent_domain_instance_message/presence_fanout.ex' " <>
            "| grep -v 'apps/ezagent_domain_session/lib/ezagent/session/read_marker.ex' " <>
            "| grep -v 'apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_channel.ex' " <>
            "| grep -v 'ezagent.check_invariants.ex' " <>
            "| grep -v '^[^:]*:[0-9]*:[[:space:]]*#' " <>
            "| grep -v '`Phoenix\\.PubSub\\.broadcast' " <>
            "| grep -v ' `PubSub' || true"
        ],
        stderr_to_stdout: true
      )

    if String.trim(output) == "" do
      Mix.shell().info("  ✓ #1 inbound via dispatch (no bare PubSub.broadcast)")
      :ok
    else
      {:error, 1, output}
    end
  end

  # Invariant #2: use Ezagent.Kind lifecycle
  # Per Decision #84: only `Ezagent.Kind.Server` should define `def init/1`.
  # Plugin Kind modules (Echo, User, etc.) declare `@behaviour Ezagent.Kind`
  # and rely on the shared server — they must not write their own init.
  defp check_invariant_2 do
    {output, _exit_code} =
      System.cmd(
        "bash",
        [
          "-c",
          "for f in $(grep -rlE '@behaviou?r Ezagent\\.Kind' apps --include='*.ex' 2>/dev/null); do " <>
            "grep -nE '^\\s*def init\\(' \"$f\" | sed \"s#^#$f:#\"; " <>
            "done " <>
            "| grep -v 'apps/ezagent_core/lib/ezagent/kind/server.ex' " <>
            "| grep -v '/test/' || true"
        ],
        stderr_to_stdout: true
      )

    if String.trim(output) == "" do
      Mix.shell().info("  ✓ #2 use Ezagent.Kind lifecycle (only Kind.Server has def init)")
      :ok
    else
      {:error, 2, output}
    end
  end

  # Invariant #3: :call to not-ready fail-fast
  # `Ezagent.Invocation.dispatch/1` must have a clause matching
  # `{:not_ready, mode}` when mode is `:call` or `:call_stream`, so that
  # synchronous callers don't block until deadline_ms.
  defp check_invariant_3 do
    {output, _exit_code} =
      System.cmd(
        "bash",
        [
          "-c",
          "grep -E ':not_ready, m\\} when m in \\[:call' " <>
            "apps/ezagent_core/lib/ezagent/invocation.ex || true"
        ],
        stderr_to_stdout: true
      )

    if String.trim(output) == "" do
      {:error, 3, "missing fail-fast clause in invocation.ex for {:not_ready, :call}"}
    else
      Mix.shell().info("  ✓ #3 :call to not-ready fail-fast (clause present)")
      :ok
    end
  end

  # Invariant #6: audit handler async-only
  # `apps/ezagent_core/lib/ezagent/audit.ex` must not write SQLite directly —
  # it should only `:telemetry`-emit, `PubSub.broadcast`, and
  # `GenServer.cast` to `Ezagent.Audit.Writer`. The SQL write lives in
  # `audit/writer.ex` per Decision #60.
  defp check_invariant_6 do
    # Look for actual code calls to Repo.insert/update/delete or exqlite
    # — skip lines that are entirely comments / docstrings (start with #
    # or ` after trimming, or contain the symbol inside backticks).
    {output, _exit_code} =
      System.cmd(
        "bash",
        [
          "-c",
          "grep -nE 'EzagentCore\\.Repo\\.(insert|update|delete)|exqlite' " <>
            "apps/ezagent_core/lib/ezagent/audit.ex " <>
            "| grep -v '^[[:space:]]*#' " <>
            "| grep -v ' `Esr\\.Repo' " <>
            "| grep -v 'Repo\\.insert.*in `audit\\.ex' || true"
        ],
        stderr_to_stdout: true
      )

    if String.trim(output) == "" do
      Mix.shell().info("  ✓ #6 audit handler async (no direct Repo writes)")
      :ok
    else
      {:error, 6, output}
    end
  end

  # Invariant #7: zero-match → DLQ unroutable
  # `Ezagent.DLQ.put/2` must accept `:unroutable` (zero-match routing
  # outcome — invariant #68 / §5.5.5 / Phase 2 chat routing). The
  # actual zero-match callsite arrives with RoutingRegistry in Phase 2;
  # Phase 1 verifies the API contract exists for use.
  defp check_invariant_7 do
    {output, _exit_code} =
      System.cmd(
        "bash",
        [
          "-c",
          "grep -E ':unroutable' apps/ezagent_core/lib/ezagent/dlq.ex || true"
        ],
        stderr_to_stdout: true
      )

    if String.trim(output) == "" do
      {:error, 7, "Ezagent.DLQ does not declare :unroutable reason"}
    else
      Mix.shell().info("  ✓ #7 zero-match → DLQ :unroutable (API present)")
      :ok
    end
  end

  # Invariant #9: Phase 3d hard flip alarm — `:stub_grant` atom no longer
  # appears in code paths (Phase 3d hard flip per P3-D6). Allowlist:
  # NOT this checker file (mentions atom in docstring), NOT docstrings
  # in general (lines starting `#` or inside `"""`). Hits = bug.
  defp check_invariant_9 do
    {output, _exit_code} =
      System.cmd(
        "bash",
        [
          "-c",
          # Match :stub_grant only outside backtick-quoted prose. Allowlist
          # files that legitimately mention the atom in their moduledoc
          # to explain the Phase 3d hard-flip rationale.
          "grep -rnE ':stub_grant' apps/ezagent_core/lib apps/ezagent_domain_session/lib " <>
            "apps/ezagent_plugin_py/lib apps/ezagent_web/lib apps/ezagent_plugin_world/lib " <>
            "--include='*.ex' 2>/dev/null " <>
            "| grep -v 'ezagent.check_invariants.ex' " <>
            "| grep -v 'lib/ezagent/telemetry.ex' " <>
            "| grep -v 'lib/ezagent/kind/runtime.ex' " <>
            "| grep -v 'lib/ezagent/audit.ex' " <>
            "| grep -v '^[^:]*:[0-9]*:[[:space:]]*#' " <>
            "| grep -v ' `:stub_grant`' || true"
        ],
        stderr_to_stdout: true
      )

    if String.trim(output) == "" do
      Mix.shell().info("  ✓ #9 :stub_grant atom not in code (Phase 3d hard flip enforced)")
      :ok
    else
      {:error, 9, output}
    end
  end

  # Invariant #10: dispatch step 5.5 grep tripwire — `Capability.matches?`
  # must be called inside `kind/runtime.ex`. Single-grep is presence-only;
  # the real cap-deny gate is `runtime_phase3d_test.exs` (per memory
  # `feedback_completion_requires_invariant_test`).
  defp check_invariant_10 do
    {output, _exit_code} =
      System.cmd(
        "bash",
        [
          "-c",
          "grep -E 'Capability\\.matches\\?' " <>
            "apps/ezagent_core/lib/ezagent/kind/runtime.ex || true"
        ],
        stderr_to_stdout: true
      )

    if String.trim(output) == "" do
      {:error, 10, "Capability.matches? not found in kind/runtime.ex — cap stub revived?"}
    else
      Mix.shell().info(
        "  ✓ #10 Capability.matches? present in dispatch path (real cap check, see " <>
          "runtime_phase3d_test.exs for runtime gate)"
      )

      :ok
    end
  end

  # Invariant #4: put_new for unique-key
  # Bare `Registry.register` (without going through KindRegistry.put_new)
  # would silently overwrite a prior live instance. Only allow it inside
  # the `put_new` wrapper in `kind_registry.ex` and tests (which set up
  # fixtures directly).
  defp check_invariant_4 do
    # Exclude:
    # - `kind_registry.ex`: the legitimate caller (wrapped in put_new)
    # - `_test.exs`: tests may use Registry directly for fixtures
    # - `ezagent.check_invariants.ex`: this file itself mentions the symbol
    #   in docstrings and the grep command literal
    {output, _exit_code} =
      System.cmd(
        "bash",
        [
          "-c",
          "grep -rnE '(^|[^A-Za-z0-9_.])Registry\\.register\\(' apps/ezagent_core/lib --include='*.ex' " <>
            "| grep -v 'kind_registry.ex' " <>
            "| grep -v '/test/' " <>
            "| grep -v '^[^:]*:[0-9]*:[[:space:]]*#' " <>
            "| grep -v 'ezagent.check_invariants.ex' || true"
        ],
        stderr_to_stdout: true
      )

    if String.trim(output) == "" do
      Mix.shell().info("  ✓ #4 put_new for unique-key (no bare Registry.register)")
      :ok
    else
      {:error, 4, output}
    end
  end

  # Comms MED Gate 1 (2026-06-26): SessionFeedChannel write handlers must route
  # by the adapter-declared participation profile, not by the historical
  # `adapter_id == "external_feed"` special case. The behavioral ChannelTest proves
  # the side effect; this source gate keeps the tripwire under
  # `mix ezagent.check_invariants`.
  defp check_comms_participation_profile_gate do
    path =
      Path.join(
        @repo_root,
        "apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex"
      )

    source = File.read!(path)

    offenders =
      for event <- ["post", "join", "history"],
          Regex.match?(
            ~r/def\s+handle_in\("#{event}"[\s\S]{0,240}adapter_id:\s*"external_feed"/,
            source
          ) do
        event
      end

    if offenders == [] do
      Mix.shell().info("  ✓ comms MED Gate 1 participation writes use participation_profile")
      :ok
    else
      {:error, "comms-med-1",
       "SessionFeedChannel write handler(s) still branch on adapter_id == \"external_feed\": " <>
         Enum.join(offenders, ", ") <>
         ". Route participatory writes by participation_profile/0 instead."}
    end
  end

  # Comms MED Gate 2 (2026-06-26): web may use the sanctioned ExternalMirror IoC
  # seam (module values + apply/3), but must not add a compile-time dependency on
  # ExternalMirror modules. Existing undeclared_umbrella_dep_test catches
  # fully-qualified hard refs, but intentionally does not resolve aliases; this
  # minimal pin closes that alias gap for ezagent_web/lib.
  defp check_web_external_mirror_ioc_gate do
    offenders =
      @repo_root
      |> Path.join("apps/ezagent_web/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> parse_file()
        |> external_mirror_aliases(path)
      end)

    if offenders == [] do
      Mix.shell().info("  ✓ comms MED Gate 2 web→external_mirror uses IoC seam only")
      :ok
    else
      {:error, "comms-med-2",
       "ezagent_web/lib directly references Ezagent.ExternalMirror modules. Use the " <>
         "sanctioned Module.concat/apply IoC seam instead. Offenders:\n" <>
         Enum.join(offenders, "\n")}
    end
  end

  defp parse_file(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(
      file: path,
      warn_on_unnecessary_quotes: false,
      emit_warnings: false
    )
  rescue
    e -> Mix.raise("AST parse failed for #{path}: #{Exception.message(e)}")
  end

  defp external_mirror_aliases(ast, path) do
    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, [:Ezagent, :ExternalMirror | rest]} = node, refs ->
          line = meta[:line] || 1
          rel = Path.relative_to(path, @repo_root)
          module = Module.concat([Ezagent, ExternalMirror | rest])
          {node, ["  #{rel}:#{line} #{inspect(module)}" | refs]}

        node, refs ->
          {node, refs}
      end)

    refs
    |> Enum.uniq()
    |> Enum.sort()
  end
end

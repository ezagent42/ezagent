defmodule Ezagent.ExternalMirror.Invariants.NoPubsubBypassTest do
  @moduledoc """
  PR-EM-FINAL invariant 1 (SPEC §10 (f) / Invariant 4).

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`:

  > **(f) No `Phoenix.PubSub.subscribe` in any module under
  > `apps/ezagent_domain_external_mirror/` or under a plugin-declared
  > binding module's transitive deps.** Grep gate. Bindings use
  > `Ezagent.Behavior.Publisher.subscribe_from/3` — never PubSub
  > directly. This is the structural enforcement that closes the P11
  > escape.

  ## Why this matters

  The whole point of the ExternalMirror Domain is to route every
  outbound mirror through `Ezagent.Invocation.dispatch/1` against
  the Worker Kind so:

  1. CapBAC step 5.5 enforces the per-Worker `:publish` cap.
  2. Per-binding crash isolation works (the Worker's
     PerBindingSupervisor catches the crash, not whatever process
     happened to receive a `Phoenix.PubSub` broadcast).
  3. Adapter `event_to_payload/1` runs inside the Worker's quantum,
     never in a Publisher consumer that the slice owner didn't
     authorize.

  A `Phoenix.PubSub.subscribe/2` call in any
  `apps/ezagent_domain_external_mirror/` module — or in a plugin's
  Binding module — bypasses ALL three properties. This grep gate
  catches the regression at test time.

  ## Allowed callsites

  - **Comments / moduledoc heredocs** — prose references to the
    forbidden pattern are filtered.
  - **`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/publisher.ex`** — defines the
    `subscribe_from/3` contract that REPLACES PubSub. Inside that
    file's implementation, the Publisher CAN use PubSub for the
    internal broadcast hop (the slice change → subscriber fan-out);
    the API surface bindings see is `Publisher.subscribe_from/3`.

  ## Plugin-declared binding modules

  V1 single-node enforcement is structural: every binding module is
  declared via `Plugin.adapters/0` and the binding module declares
  `@behaviour Ezagent.ExternalMirror.Binding` at the source level.

  Source-level scan strategy (codex r1 P1 fix; the prior `:code.which/1`
  → snake-case-path mapping silently mapped to non-existent files):
  Phase 1 greps every `.ex` under `apps/` for a top-of-line
  `@behaviour Ezagent.ExternalMirror.Binding` declaration; Phase 2
  greps the owning app's `lib/` tree for `Phoenix.PubSub.subscribe`.

  ## Vacuous-pass posture today

  At the time PR-EM-FINAL lands, NO production binding module exists
  on main (PR-EM-6 — FeishuChatBinding — is the first one and was in
  flight in a separate branch). The plugin-side gate therefore scans
  zero apps and is vacuously green. This is **intentional + correct**:
  the gate fires the moment a real binding lands, NOT before. The
  Domain-side gate (test #1) above always runs against
  `apps/ezagent_domain_external_mirror/lib/` regardless.
  """
  use ExUnit.Case, async: true

  @forbidden ~r/Phoenix\.PubSub\.subscribe/

  test "no Phoenix.PubSub.subscribe under apps/ezagent_domain_external_mirror/lib/" do
    domain_lib =
      Path.join(apps_root(), "ezagent_domain_external_mirror/lib")

    violations = scan_dir(domain_lib)

    assert violations == [],
           """
           Phoenix.PubSub.subscribe found in ExternalMirror Domain — violates
           SPEC §10 (f) / Invariant 4. Bindings MUST use
           `Ezagent.Behavior.Publisher.subscribe_from/3` so the per-binding
           Worker Kind is the only path between Session slice changes and
           adapter publish — preserving crash isolation + CapBAC enforcement.

           Offenders:
           #{Enum.join(violations, "\n")}
           """
  end

  test "no Phoenix.PubSub.subscribe in any source file declaring @behaviour Ezagent.ExternalMirror.Binding (or its same-app helpers)" do
    # Two-phase scan:
    #   Phase 1 — grep every `.ex` under `apps/` for a source-level
    #     `@behaviour Ezagent.ExternalMirror.Binding` declaration;
    #     collect the OWNING APP directories.
    #   Phase 2 — grep every `.ex` under those owning-app `lib/` trees
    #     for `Phoenix.PubSub.subscribe`. Covers BOTH the Binding
    #     module itself AND any same-app helper it transitively calls
    #     (SPEC §10 (f) "binding module's transitive deps" — for V1
    #     single-node, "transitive deps" reduces to "same plugin app
    #     code" because plugin authors don't reach across plugin apps).
    #
    # Source-level @behaviour grep avoids the `:code.which/1` →
    # snake-case-path mapping fragility codex r1 P1 caught (the prior
    # implementation derived `apps/<app>/lib/Elixir.Some.Mod.ex` from
    # `_build/.../Elixir.Some.Mod.beam` — that path NEVER exists since
    # real source paths are snake_case + nested directories).

    binding_apps = find_apps_with_binding_modules()

    violations =
      binding_apps
      |> Enum.flat_map(fn app_lib -> scan_dir_for_forbidden(app_lib) end)

    assert violations == [],
           """
           Phoenix.PubSub.subscribe found in a plugin app that declares
           an ExternalMirror Binding — violates SPEC §10 (f) / Invariant 4.

           The ExternalMirror Domain replaces the historical "binding
           subscribes directly to PubSub" pattern (the P11 escape) with
           `Publisher.subscribe_from/3` consumed by the Worker Kind only.
           A binding (or any helper it transitively calls in the same
           plugin app) that subscribes directly bypasses the per-binding
           crash boundary AND the Worker `:publish` cap gate — REGRESSION.

           If a binding-hosting plugin needs PubSub for UNRELATED concerns
           (e.g. an admin LV's audit topic subscription), separate that
           code into a different app — or split the binding into its own
           plugin app so this gate's app-level scoping is sound.

           Offenders:
           #{Enum.join(violations, "\n")}

           Apps scanned (declare an ExternalMirror Binding):
           #{Enum.join(binding_apps, "\n")}
           """
  end

  # Phase 1 — find every app whose `lib/` contains a source file with
  # an ACTUAL `@behaviour Ezagent.ExternalMirror.Binding` declaration
  # at the top of a line (i.e. module-level attribute, NOT a runtime
  # mention inside a string/AST inspection in something like
  # `ezagent_plugin_check.ex`).
  #
  # Regex: optional leading whitespace + literal `@behaviour` + ws +
  # the fully-qualified module + word-boundary. Excludes any line where
  # the `@behaviour` is preceded by `:` (atom in a list), `"` (string),
  # backtick (doc), or `,` (inside a list literal).
  defp find_apps_with_binding_modules do
    {output, _exit} =
      System.cmd(
        "grep",
        [
          "-rEl",
          "^\\s*@behaviour\\s+Ezagent\\.ExternalMirror\\.Binding\\b",
          apps_root(),
          "--include=*.ex"
        ],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&owning_app_lib_dir/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Map a source path like `/.../apps/ezagent_plugin_feishu/lib/.../foo.ex`
  # to `/.../apps/ezagent_plugin_feishu/lib`. Returns nil if the path
  # doesn't sit under `apps/<app>/lib/`.
  defp owning_app_lib_dir(path) do
    case Regex.run(~r{^(.+/apps/[^/]+/lib)/}, path) do
      [_, lib_dir] -> lib_dir
      _ -> nil
    end
  end

  # Phase 2 — grep one app's lib/ for forbidden PubSub subscribes.
  # Reuses the prose-reference + comment filters from scan_dir/1.
  defp scan_dir_for_forbidden(lib_dir), do: scan_dir(lib_dir)

  defp scan_dir(dir) do
    {output, _exit} =
      System.cmd(
        "grep",
        ["-rEn", @forbidden.source, dir, "--include=*.ex"],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&comment_or_docstring?/1)
  end

  # Comment lines / prose references inside moduledoc / @doc heredocs
  # are filtered. The pattern matches the live code surface only.
  defp comment_or_docstring?(line) do
    case String.split(line, ":", parts: 3) do
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
    case String.split(body, "Phoenix.PubSub.subscribe", parts: 2) do
      [prefix, _] ->
        String.contains?(prefix, "`") or String.contains?(prefix, "→")

      _ ->
        false
    end
  end

  defp apps_root do
    {out, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    Path.join(String.trim(out), "apps")
  end
end

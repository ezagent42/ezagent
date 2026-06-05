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
  `@behaviour Ezagent.ExternalMirror.Binding` (either spelled-out
  or via `alias`).

  Discovery strategy (codex r2 P2 fix — was missing aliased
  declarations like `alias Ezagent.ExternalMirror.Binding` followed
  by `@behaviour Binding`):

  - **Phase 1 — runtime module discovery.** Walk `:code.all_loaded/0`
    and filter modules whose `module_info(:attributes)[:behaviour]`
    list contains `Ezagent.ExternalMirror.Binding`. This catches the
    aliased AND the fully-qualified spelling — Elixir resolves both
    to the same attribute value at compile time.
  - **Phase 2 — source-file lookup via beam compile_info.** Use
    `:beam_lib.chunks(beam_path, [:compile_info])[:source]` to get
    the absolute source path the compiler recorded. This avoids the
    `:code.which/1` → snake-case-path fragility codex r1 P1 caught.
  - **Phase 3 — owning-app lib scan.** For each binding source path,
    derive `apps/<app>/lib/` and grep the full tree for
    `(?:Phoenix\.)?PubSub\.subscribe` — catches both fully-qualified
    AND aliased `alias Phoenix.PubSub` + `PubSub.subscribe` (codex r2
    P2).

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

  # Match BOTH the fully-qualified call AND the aliased form
  # (`alias Phoenix.PubSub` followed by `PubSub.subscribe`). Codex r2
  # P2: the original `Phoenix\.PubSub\.subscribe` regex silently
  # missed the aliased shape — valid Elixir spelling that bypasses
  # the gate without violating any other contract.
  @forbidden ~r/(?:Phoenix\.)?PubSub\.subscribe/

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
    # Three-phase scan (codex r2 P2 fix — discovery now uses runtime
    # module attributes, not source-text regex, so aliased
    # `alias Ezagent.ExternalMirror.Binding` declarations are caught):
    #
    #   Phase 1 — `:code.all_loaded/0` filtered by
    #     `module_info(:attributes)[:behaviour]` containing
    #     `Ezagent.ExternalMirror.Binding`. Elixir resolves both
    #     `@behaviour Ezagent.ExternalMirror.Binding` AND
    #     `alias Ezagent.ExternalMirror.Binding` + `@behaviour Binding`
    #     to the same compile-time attribute value.
    #   Phase 2 — `:beam_lib.chunks(beam, [:compile_info])[:source]`
    #     gives the absolute source path the compiler recorded.
    #   Phase 3 — grep each owning-app's lib/ tree for the forbidden
    #     pattern. Covers Binding modules AND same-app helpers.

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

  # Phase 1+2 — beam-walk + runtime-attribute discovery. Enumerates
  # every `.beam` under `_build/<env>/lib/<app>/ebin/`, ensures the
  # module is loaded (Code.ensure_loaded/1 — lazy modules wouldn't
  # show up in `:code.all_loaded/0` in a fresh ExUnit process),
  # filters by `@behaviour Ezagent.ExternalMirror.Binding`, then
  # maps each to its source via `:beam_lib.chunks/2`'s `:compile_info`
  # chunk and the owning `apps/<app>/lib/` directory.
  #
  # This is robust against the codex r2 P2 alias finding: Elixir
  # records the resolved module atom in `:behaviour` attributes, so
  # both spellings (`@behaviour Ezagent.ExternalMirror.Binding` AND
  # `alias Ezagent.ExternalMirror.Binding` + `@behaviour Binding`)
  # produce the same attribute value.
  defp find_apps_with_binding_modules do
    all_beams()
    |> Enum.map(&module_from_beam/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&ensure_loaded/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&binding_behaviour?/1)
    |> Enum.flat_map(&source_for_module/1)
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&owning_app_lib_dir/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp all_beams do
    build_dir = Path.join([umbrella_root(), "_build", to_string(Mix.env()), "lib"])

    case File.ls(build_dir) do
      {:ok, apps} ->
        Enum.flat_map(apps, fn app ->
          ebin = Path.join([build_dir, app, "ebin"])

          # CRITICAL: prepend each app's ebin to the BEAM code path so
          # `Code.ensure_loaded/1` can find modules from apps that AREN'T
          # listed in this app's mix.exs deps. Without this, the test
          # only sees modules from `:ezagent_core` + `:ezagent_domain_identity`
          # (this app's declared deps) and silently misses any binding
          # module defined in `:ezagent_plugin_*` (a sibling app, not a
          # dep) — that's a false-negative on the SPEC §10 (f) gate.
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
    base = Path.basename(beam_path, ".beam")
    String.to_atom(base)
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
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
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

  defp binding_behaviour?(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(Ezagent.ExternalMirror.Binding)
  rescue
    _ -> false
  end

  # Returns the absolute source path the compiler recorded for a
  # module, OR `[]` if unavailable (some test-only modules have no
  # `:compile_info` chunk). Single-element list so callers can use
  # `Enum.flat_map/2`.
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

  # Heuristic: a line where the forbidden call appears inside backticks
  # OR after the arrow `→` (used in moduledoc / @doc tables) is prose,
  # not a real call site. Both the fully-qualified `Phoenix.PubSub.subscribe`
  # AND the aliased `PubSub.subscribe` are handled (codex r2 P2 fix —
  # the forbidden pattern now matches both spellings).
  defp prose_reference?(body) do
    cond do
      contains_with_backtick?(body, "PubSub.subscribe") -> true
      String.contains?(body, "→ PubSub.subscribe") -> true
      String.contains?(body, "→ Phoenix.PubSub.subscribe") -> true
      true -> false
    end
  end

  defp contains_with_backtick?(body, marker) do
    case String.split(body, marker, parts: 2) do
      [prefix, _] -> String.contains?(prefix, "`")
      _ -> false
    end
  end

  defp apps_root do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
        {top, 0} ->
          top

        _ ->
          # No .git inside the release image (#21 docker) — resolve the
          # umbrella root from cwd (umbrella root or the app under test).
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end
    Path.join(String.trim(out), "apps")
  end
end

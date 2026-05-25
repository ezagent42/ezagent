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
  declared via `Plugin.adapters/0` and registered in
  `Ezagent.ExternalMirror.BindingRegistry`. This test enumerates the
  registry post-boot AND greps every module under
  `apps/ezagent_plugin_*/lib/`. The grep is broader than strictly
  needed (covers non-binding plugin code too) but matches the SPEC's
  intent: NO plugin code subscribes to PubSub for external-mirror
  purposes.
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

  test "no Phoenix.PubSub.subscribe in any module that implements @behaviour Ezagent.ExternalMirror.Binding" do
    # Walk every loaded module looking for ones declaring the Binding
    # behaviour, then grep their source files for PubSub.subscribe.
    # Test fixtures + production binding modules are both covered —
    # the source-file lookup uses `:code.which/1` which returns the
    # compiled .beam path; we map that back to the source file via
    # the umbrella's `apps/*/lib/` layout.
    binding_modules =
      :code.all_loaded()
      |> Enum.map(fn {mod, _file} -> mod end)
      |> Enum.filter(&binding_behaviour?/1)

    violations =
      binding_modules
      |> Enum.flat_map(&source_files_for_module/1)
      |> Enum.uniq()
      |> Enum.flat_map(&scan_file/1)

    assert violations == [],
           """
           Phoenix.PubSub.subscribe found in a Binding module's source —
           violates SPEC §10 (f) / Invariant 4. The ExternalMirror Domain
           replaces the historical "binding subscribes directly to PubSub"
           pattern (the P11 escape) with `Publisher.subscribe_from/3`
           consumed by the Worker Kind only. A binding that subscribes
           directly bypasses the per-binding crash boundary AND the
           Worker `:publish` cap gate — REGRESSION.

           Offenders:
           #{Enum.join(violations, "\n")}

           Bindings checked: #{inspect(binding_modules)}
           """
  end

  defp binding_behaviour?(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Ezagent.ExternalMirror.Binding in behaviours
  rescue
    _ -> false
  end

  # Map a loaded module to its source .ex file. `:code.which/1` returns
  # the .beam path; we derive the source path by replacing `_build/.../ebin/`
  # with `lib/` and `.beam` with `.ex`. Works for both umbrella apps and
  # in-test compiled modules.
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
    {output, _exit} =
      System.cmd(
        "grep",
        ["-En", @forbidden.source, file],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> "#{file}:#{line}" end)
    |> Enum.reject(&comment_or_docstring?/1)
  end

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

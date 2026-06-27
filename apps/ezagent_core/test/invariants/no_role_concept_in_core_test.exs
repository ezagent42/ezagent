defmodule EzagentCore.Invariants.NoRoleConceptInCoreTest do
  @moduledoc """
  role-as-data structural gate — the ROLE REGISTRY must not re-enter `ezagent_core`.

  `Ezagent.Agent.RoleRegistry` resolves roles READ-THROUGH over
  `Ezagent.Socialware.ConfigStore` (an `ezagent_domain_identity` concern), so it
  lives in `ezagent_domain_agent` (which deps identity). If a future change
  re-introduced a `RoleRegistry` reference into `ezagent_core/lib`, core would
  again reach (transitively) for identity/ConfigStore — re-creating the
  no-core→identity layering violation this relocation removed. This gate makes
  that structurally impossible: it FAILS if any `ezagent_core/lib` Elixir file
  references a `RoleRegistry` module (in ANY namespace —
  `Ezagent.Agent.RoleRegistry`, a bare aliased `RoleRegistry`, etc.).

  ## What is ALLOWED in core (NOT flagged)

  - `Ezagent.Role` / `Ezagent.Role.Compose` / `Ezagent.Role.CapMint` — the role
    RECIPE struct + its context-free composition legitimately live in core (the
    validation boundary; they touch no store). The role *concept* in core is
    fine; the role *registry/store* is what may not.
  - `Ezagent.Plugin.RoleSeedHook` — core's OWN registered-hook seam (the
    indirection that lets core seed roles WITHOUT referencing the downstream
    registry). It is defined in core; its name does not end in `:RoleRegistry`.

  ## Why AST, not grep

  The scan walks the parsed AST for `__aliases__` nodes whose LAST segment is
  `RoleRegistry`. Comments and docstrings that merely MENTION the module (several
  core moduledocs explain the relocation) are NOT code references and are
  correctly ignored — only a real module reference trips the gate.

  Mirrors `EzagentCore.Invariants.LayerPurityTest` (same repo-root anchoring via
  `git rev-parse --show-toplevel`, NOT a CWD-relative wildcard).
  """
  use ExUnit.Case, async: true

  test "ezagent_core/lib has zero RoleRegistry module references" do
    offending =
      core_lib_files()
      |> Enum.flat_map(&role_registry_references_in_file/1)

    assert offending == [],
           """
           ezagent_core/lib must not reference a RoleRegistry module.

           The role registry (`Ezagent.Agent.RoleRegistry`) resolves over
           `Ezagent.Socialware.ConfigStore` (an ezagent_domain_identity concern),
           so it lives in ezagent_domain_agent. A reference in core would re-create
           the no-core→identity layering violation. Seed roles via the
           `Ezagent.Plugin.RoleSeedHook` seam instead (core stays clean).

           Offending references:
           #{Enum.join(offending, "\n")}
           """
  end

  defp core_lib_files do
    Path.join([repo_root(), "apps", "ezagent_core", "lib", "**", "*.ex"])
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp role_registry_references_in_file(path) do
    ast =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path)

    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, atoms} = node, refs when is_list(atoms) ->
          if List.last(atoms) == :RoleRegistry do
            {node, [{meta[:line] || 1, Module.concat(atoms)} | refs]}
          else
            {node, refs}
          end

        node, refs ->
          {node, refs}
      end)

    refs
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {line, module} ->
      "#{Path.relative_to(path, repo_root())}:#{line} #{inspect(module)}"
    end)
  end

  defp repo_root do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {top, 0} ->
          top

        _ ->
          # No .git inside the release image (#21 docker) — resolve the umbrella
          # root from cwd (umbrella root or the app under test).
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end

    String.trim(out)
  end
end

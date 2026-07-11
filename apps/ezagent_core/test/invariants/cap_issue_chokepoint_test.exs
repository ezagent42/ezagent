defmodule Ezagent.Invariants.CapIssueChokepointTest do
  @moduledoc """
  I7: ratchet every provenance-bearing capability construction and every
  explicit `:caps` slice write while Phase 3 moves them behind `Cap.issue/3`.

  S1 introduced the leg-2 shrink-only allowlist. S4 adds leg 1: the one
  capability-adding writer is verification-gated, while revoke remains a
  monotonic removal. Later stages may only shrink these counts as proposed-cap
  constructors become issue callers; widening either map is a review-blocking
  chokepoint bypass.
  """
  use ExUnit.Case, async: true

  @mint_candidates %{
    "apps/ezagent_core/lib/ezagent/cap.ex" => 1,
    "apps/ezagent_core/lib/ezagent/capability/normalize.ex" => 3,
    "apps/ezagent_core/lib/ezagent/capability/parser.ex" => 2,
    "apps/ezagent_core/lib/ezagent/capability_registry.ex" => 1,
    "apps/ezagent_core/lib/ezagent/creator_grant.ex" => 1,
    "apps/ezagent_core/lib/ezagent/kind/runtime.ex" => 1,
    "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex" => 2,
    "apps/ezagent_domain_identity/lib/ezagent/identity.ex" => 2,
    "apps/ezagent_domain_session/lib/ezagent/behavior/template.ex" => 2,
    "apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex" => 3,
    "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex" => 3,
    "apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex" => 1,
    "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex" => 1,
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex" =>
      1,
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex" =>
      4,
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex" =>
      1,
    "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex" => 1,
    "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex" => 1,
    "apps/ezagent_plugin_email/lib/ezagent/email/inbound/principal.ex" => 1,
    "apps/ezagent_plugin_world/lib/ezagent/world/layout_bootstrap.ex" => 1,
    "apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_actions.ex" => 1
  }
  @mint_candidate_files 21
  @mint_candidate_sites 34

  @caps_writers %{
    "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex" => 2
  }
  @caps_writer_files 1
  @caps_writer_sites 2

  test "provenance-bearing capability construction allowlist can only shrink" do
    actual = provenance_constructors()

    assert actual == @mint_candidates,
           "capability constructor ratchet changed; migrate new sites through Cap.issue, never widen:\n#{inspect(actual, pretty: true)}"

    assert map_size(@mint_candidates) == @mint_candidate_files
    assert Enum.sum(Map.values(@mint_candidates)) == @mint_candidate_sites
  end

  test "explicit caps-slice writer allowlist can only shrink" do
    actual = caps_writers()

    assert actual == @caps_writers,
           "caps writer ratchet changed; no new store path may bypass the issue/store model:\n#{inspect(actual, pretty: true)}"

    assert map_size(@caps_writers) == @caps_writer_files
    assert Enum.sum(Map.values(@caps_writers)) == @caps_writer_sites
  end

  test "I7 leg 1 classifies the adding writer as verified and revoke as removal-only" do
    identity =
      repo_root()
      |> Path.join("apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex")
      |> File.read!()

    store = between(identity, "defp store_verified_cap", "def handle_revoke_cap")
    revoke = between(identity, "def handle_revoke_cap", "defp uri_to_str")

    assert store =~ "Ezagent.Cap.verify(cap_struct)"
    assert store =~ "{:set, :caps, new_caps}"
    assert revoke =~ "Ezagent.Capability.revoke(current_caps, cap_struct)"
    refute revoke =~ "MapSet.put"
  end

  defp provenance_constructors do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      ast = quoted!(absolute)

      {_ast, count} =
        Macro.prewalk(ast, 0, fn node, count ->
          {node, count + provenance_constructor?(node)}
        end)

      if count == 0, do: acc, else: Map.put(acc, relative, count)
    end)
  end

  defp provenance_constructor?({:%, _, [alias_ast, {:%{}, _, fields}]}) when is_list(fields) do
    if String.ends_with?(Macro.to_string(alias_ast), "Capability") and
         Keyword.has_key?(fields, :granted_by),
       do: 1,
       else: 0
  end

  defp provenance_constructor?(_node), do: 0

  defp caps_writers do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      ast = quoted!(absolute)

      {_ast, count} =
        Macro.prewalk(ast, 0, fn
          {:{}, _, [:set, :caps | _]} = node, count -> {node, count + 1}
          node, count -> {node, count}
        end)

      if count == 0, do: acc, else: Map.put(acc, relative, count)
    end)
  end

  defp source_files do
    root = repo_root()

    root
    |> Path.join("apps/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&{String.replace_prefix(&1, root <> "/", ""), &1})
  end

  defp quoted!(file) do
    case Code.string_to_quoted(File.read!(file)) do
      {:ok, ast} -> ast
      {:error, reason} -> raise "cannot scan #{file}: #{inspect(reason)}"
    end
  end

  defp between(source, first, last) do
    [_, tail] = String.split(source, first, parts: 2)
    [section | _] = String.split(tail, last, parts: 2)
    section
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end

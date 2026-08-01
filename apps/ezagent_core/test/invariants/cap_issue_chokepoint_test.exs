defmodule Ezagent.Invariants.CapIssueChokepointTest do
  @moduledoc """
  Ratchets provenance-bearing capability construction and live `:caps` slice
  writes. Durable carrier ownership is enforced separately by
  `CleanSlateGrantProtocolTest`: users have no cap column and Store is the sole
  raw carrier.
  """
  use ExUnit.Case, async: true

  @mint_candidates %{
    "apps/ezagent_core/lib/ezagent/cap/authority.ex" => 2,
    "apps/ezagent_core/lib/ezagent/capability/normalize.ex" => 3,
    "apps/ezagent_core/lib/ezagent/capability/parser.ex" => 2,
    "apps/ezagent_core/lib/ezagent/capability_registry.ex" => 1,
    "apps/ezagent_core/lib/ezagent/creator_grant.ex" => 1,
    "apps/ezagent_domain_identity/lib/ezagent/identity.ex" => 1,
    "apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex" => 3,
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex" =>
      4,
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex" =>
      1,
    "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex" => 1,
    "apps/ezagent_domain_workspace/lib/ezagent/workspace/member_caps.ex" => 1
  }

  @caps_writers %{
    "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex" => 1
  }

  test "provenance-bearing capability construction allowlist can only shrink" do
    assert provenance_constructors() == @mint_candidates
  end

  test "explicit caps-slice writer allowlist can only shrink" do
    assert caps_writers() == @caps_writers
  end

  test "the adding writer validates and persists before exposing a live effect" do
    identity =
      repo_root()
      |> Path.join("apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex")
      |> File.read!()

    persist = between(identity, "def handle_persist_caps", "defp store_verified_cap")
    store = between(identity, "defp store_verified_cap", "def handle_revoke_cap")
    revoke = between(identity, "def handle_revoke_cap", "defp uri_to_str")
    writer = between(identity, "defp set_caps_effect", "defp normalize_artifact")

    assert store =~ "Ezagent.Cap.storable_for?(cap_struct"
    assert persist =~ "persist_entity_caps(receiver, new_caps)"
    assert store =~ "persist_entity_caps(receiver, new_caps)"
    assert persist =~ "set_caps_effect(new_caps)"
    assert store =~ "set_caps_effect(new_caps)"
    assert revoke =~ "set_caps_effect(new_caps)"
    assert writer =~ "{:set, :caps, caps}"
    assert revoke =~ "Ezagent.IdentityCaps.Store.revoke_cap(receiver, revocation_artifact)"
    assert revoke =~ "Ezagent.Capability.revoke(current_caps, resolved)"
    refute revoke =~ "MapSet.put"
  end

  defp provenance_constructors do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      {_ast, count} =
        Macro.prewalk(quoted!(absolute), 0, fn node, count ->
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
      {_ast, count} =
        Macro.prewalk(quoted!(absolute), 0, fn
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
    |> Enum.reject(&EzagentCore.AstScan.tmp_fixture?/1)
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

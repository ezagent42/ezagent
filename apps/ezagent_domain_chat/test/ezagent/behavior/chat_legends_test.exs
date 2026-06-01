defmodule Ezagent.Behavior.ChatLegendsTest do
  @moduledoc """
  team-routing-unification §3.6 (PR-6) — the domain seam between the Chat
  session slice (where the session-scoped legend registry lives, alongside
  `:members`) and the core `Ezagent.Routing.Legend` resolution layer.

  Covers:
    * the `:legends` slice field default (legacy snapshots → `%{}`)
    * the `chat.set_legends` handler + its authorization (orchestrator /
      system-internal only — same authority class as `set_working_copy`)
    * `Chat.legends_of/1` reader + `Chat.resolve_legend/2` (GATE a — a legend
      resolves to its bound rule-set entry via the registry)
    * `Chat.fold_members/2` wiring `role_name_to_uri` into `Legend.fold_members`
      (GATE c — folded members collapse but stay individually @-able)
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Chat
  alias Ezagent.Routing.Legend

  defp uri(s), do: URI.new!(s)

  describe "slice default — :legends" do
    test "a fresh session's :chat state carries an empty legends map" do
      {:ok, state} = Chat.create(%{owner_uri: uri("entity://user/system/admin")})
      assert state.legends == %{}
    end

    test "legends_of/1 defaults a legacy (key-absent) slice to %{}" do
      assert Chat.legends_of(%{}) == %{}
      assert Chat.legends_of(%{members: %{}}) == %{}
    end

    test "legends_of/1 reads an installed registry" do
      legends = Legend.put(%{}, "team", member_set: ["a"], bound_rule_set: "rs")
      assert Chat.legends_of(%{legends: legends}) == legends
    end
  end

  describe "handle_set_legends/2 — install path + authorization" do
    test "system-internal ctx is authorized → emits a {:set, :legends, ...} effect" do
      legends = Legend.put(%{}, "传话游戏", member_set: ["relay-cc"], bound_rule_set: "telephone")

      ctx = %{self_uri: uri("session://default/team/s1"), system_internal: true}

      assert {:ok, %{legends: ^legends}, effects} = Chat.handle_set_legends(%{legends: legends}, ctx)
      assert Enum.any?(effects, fn {:set, :legends, l} -> l == legends; _ -> false end)
    end

    test "the session's orchestrator (within_session cap) is authorized" do
      sess = uri("session://default/team-alpha/s1")
      legends = Legend.put(%{}, "team", member_set: [], bound_rule_set: "rs")

      orch_cap = %Ezagent.Capability{
        kind: :session,
        behavior: Chat,
        action: :set_legends,
        instance: {:within_session, sess},
        workspace_uri: URI.parse("workspace://team-alpha"),
        granted_by: URI.parse("system://test"),
        granted_at: DateTime.utc_now()
      }

      ctx = %{self_uri: sess, caps: MapSet.new([orch_cap])}

      assert {:ok, _, effects} = Chat.handle_set_legends(%{legends: legends}, ctx)
      assert Enum.any?(effects, fn {:set, :legends, l} -> l == legends; _ -> false end)
    end

    test "a plain session-cap holder (no orchestrator authority) is denied" do
      ctx = %{self_uri: uri("session://default/team/s1"), caps: MapSet.new()}
      assert {:error, :unauthorized} = Chat.handle_set_legends(%{legends: %{}}, ctx)
    end
  end

  # GATE (a) — `@legend` resolves via the registry → its bound rule-set entry.
  describe "resolve_legend/2 (GATE a)" do
    test "a slice's legend resolves to its bound rule-set entry" do
      legends =
        Legend.put(%{}, "传话游戏", member_set: ["relay-cc"], bound_rule_set: "telephone", fold: true)

      slice = %{legends: legends}

      assert {:ok, entry} = Chat.resolve_legend(slice, "传话游戏")
      assert entry.bound_rule_set == "telephone"
      assert entry.name == "传话游戏"
    end

    test "resolve_legend/2 is :error for a non-legend / empty slice" do
      assert :error = Chat.resolve_legend(%{legends: %{}}, "nope")
      assert :error = Chat.resolve_legend(%{}, "nope")
    end
  end

  # GATE (c) — fold hides folded-legend members but they stay individually
  # @-able (the SoT members map is untouched + role_name_to_uri still resolves).
  describe "fold_members/2 (GATE c) — wires role_name_to_uri into Legend.fold_members" do
    test "folded legend members collapse into one legend row; non-members untouched" do
      relay_cc = uri("entity://agent/team/cc_relay")
      relay_codex = uri("entity://agent/team/codex_relay")
      admin = uri("entity://user/system/admin")

      members = %{
        relay_cc => %{online: true, role_name: "relay-cc"},
        relay_codex => %{online: true, role_name: "relay-codex"},
        admin => %{online: true}
      }

      legends =
        Legend.put(%{}, "传话游戏",
          member_set: ["relay-cc", "relay-codex"],
          bound_rule_set: "telephone",
          fold: true
        )

      slice = %{members: members, legends: legends}
      folded = Chat.fold_members(slice)

      assert Enum.any?(folded, fn
               {:legend, "传话游戏", uris} ->
                 Enum.sort(Enum.map(uris, &URI.to_string/1)) ==
                   Enum.sort([URI.to_string(relay_cc), URI.to_string(relay_codex)])

               _ ->
                 false
             end)

      assert Enum.any?(folded, fn
               {:member, ^admin, _} -> true
               _ -> false
             end)

      # The folded members are NOT plain rows...
      refute Enum.any?(folded, fn
               {:member, u, _} -> u in [relay_cc, relay_codex]
               _ -> false
             end)

      # ...but they remain individually @-able: the SoT members map is
      # untouched, so a concrete @relay-cc still resolves to the live member.
      assert Chat.role_name_to_uri(members, "relay-cc") == relay_cc
      assert Chat.role_name_to_uri(members, "relay-codex") == relay_codex
    end

    test "no legends → every member is a plain row" do
      admin = uri("entity://user/system/admin")
      slice = %{members: %{admin => %{online: true}}, legends: %{}}

      assert Chat.fold_members(slice) == [{:member, admin, %{online: true}}]
    end
  end
end

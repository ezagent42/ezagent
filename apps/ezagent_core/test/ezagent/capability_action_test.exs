defmodule Ezagent.CapabilityActionTest do
  @moduledoc """
  SPEC 2026-05-27 capability-action-axis §5 — acceptance criteria
  A1-A4 + C1 + the matcher-tolerance regression test (B3 lives in
  `test/integration/cap_action_axis_snapshot_restore_test.exs`).

  Pure-data assertions on the matcher's action-axis semantics — no
  Repo, no GenServer, no boot. Async-safe.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Capability

  describe "A1 — cap/3 stores the action atom" do
    test "Capability.cap(:chat, Chat, :send).action == :send" do
      cap = Capability.cap(:chat, Ezagent.Behavior.Chat, :send)
      assert cap.action == :send
    end

    test "Capability.cap(:chat, Chat, :any).action == :any (declarative wildcard)" do
      cap = Capability.cap(:chat, Ezagent.Behavior.Chat, :any)
      assert cap.action == :any
    end

    test "Capability.cap/5 stores the action atom" do
      session_uri = URI.new!("session://default/team-alpha/main")
      workspace_uri = URI.new!("workspace://team-alpha")

      cap =
        Capability.cap(:session, Ezagent.Behavior.Chat, :send, session_uri, workspace_uri)

      assert cap.action == :send
      assert cap.instance == session_uri
      assert cap.workspace_uri == workspace_uri
    end
  end

  describe "A2 — narrow action does NOT match a different action" do
    test "held :send does NOT authorize needed :join" do
      held = build_held_cap(:send)
      needed = build_needed(:join)

      refute Capability.matches?(held, needed),
             "a held cap narrowed to :send MUST NOT satisfy a needed :join cap-check — that's the PR #408 round-3 over-grant bug this SPEC fixes"
    end

    test "held :add_member does NOT authorize needed :create_session (the canonical bug)" do
      held = %Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :add_member,
        instance: :any,
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: URI.new!("system://bootstrap"),
        granted_at: DateTime.utc_now()
      }

      needed = %{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :create_session,
        instance: URI.new!("workspace://team-alpha"),
        workspace_uri: URI.new!("workspace://team-alpha")
      }

      refute Capability.matches?(held, needed),
             "the PR #408 round-3 case: a workspace member cap intended for :add_member must NOT cover :create_session"
    end
  end

  describe "A3 — :any action wildcard preserves match" do
    test "held action :any matches needed :send" do
      held = build_held_cap(:any)
      needed = build_needed(:send)

      assert Capability.matches?(held, needed),
             "an action-wildcard held cap MUST match a concrete needed action — the matcher's `:any` wildcard semantics for the action axis must mirror the kind/behavior axes"
    end

    test "held action :send matches needed :send (identity)" do
      held = build_held_cap(:send)
      needed = build_needed(:send)

      assert Capability.matches?(held, needed)
    end
  end

  describe "A4 — old JSON row (6 fields, no action) loads as :any" do
    test "from_map shim defaults missing \"action\" to \"any\" before atomization" do
      old_row = %{
        "kind" => "chat",
        "behavior" => "Ezagent.Behavior.Chat",
        "instance" => "any",
        "workspace_uri" => "workspace://team-alpha",
        "granted_by" => "entity://user/system/admin",
        "granted_at" => "2026-01-01T00:00:00Z"
      }

      refute Map.has_key?(old_row, "action"),
             "test fixture invariant: the old row genuinely lacks an `\"action\"` key"

      cap = Capability.from_map(old_row)

      assert cap.action == :any,
             "Capability.from_map/1 MUST inject `\"action\" => \"any\"` before atomization for pre-action-axis JSON rows (SPEC §3.4 backward-compat read path)"
    end

    test "round-trip: from_map(to_map(cap)) preserves action" do
      original = build_held_cap(:send)
      round_tripped = original |> Capability.to_map() |> Capability.from_map()

      assert round_tripped.action == :send,
             "to_map/from_map must be lossless on the action axis"
    end

    test "action_of/1 returns :any for caps with no :action key" do
      legacy = Map.delete(build_held_cap(:any), :action)

      refute Map.has_key?(legacy, :action),
             "test fixture invariant: the legacy cap genuinely lacks :action"

      assert Capability.action_of(legacy) == :any,
             "action_of/1 MUST be missing-key tolerant per §3.3.1"
    end
  end

  describe "C1 — admin full-wildcard cap matches every action" do
    test "kind: :any, behavior: :any, action: :any matches a concrete needed cap" do
      admin = %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: URI.parse("system://bootstrap/default"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      needed = build_needed(:add_member)

      assert Capability.matches?(admin, needed),
             "admin's full-wildcard cap MUST match every needed cap — that's the structural invariant of admin authority"
    end

    test "Capability.admin_invariant?/1 recognises the 5-axis full wildcard" do
      admin = %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: URI.parse("system://bootstrap/default"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      assert Capability.admin_invariant?(admin),
             "admin_invariant?/1 must accept the new 5-axis wildcard shape"
    end

    test "Capability.admin_invariant?/1 recognises legacy 4-axis wildcard (snapshot-restored)" do
      legacy =
        Map.delete(
          %Capability{
            kind: :any,
            behavior: :any,
            action: :any,
            instance: :any,
            workspace_uri: :any,
            granted_by: URI.parse("system://bootstrap/default"),
            granted_at: ~U[2026-01-01 00:00:00Z]
          },
          :action
        )

      refute Map.has_key?(legacy, :action),
             "test fixture invariant: the legacy cap genuinely lacks :action"

      assert Capability.admin_invariant?(legacy),
             "admin_invariant?/1 must recognise pre-SPEC snapshot-restored caps via the legacy clause"
    end
  end

  # ----- helpers -----

  defp build_held_cap(action) do
    %Capability{
      kind: :session,
      behavior: Ezagent.Behavior.Chat,
      action: action,
      instance: :any,
      workspace_uri: :any,
      granted_by: URI.parse("entity://user/system/admin"),
      granted_at: ~U[2026-01-01 00:00:00Z]
    }
  end

  defp build_needed(action) do
    %{
      kind: :session,
      behavior: Ezagent.Behavior.Chat,
      action: action,
      instance: URI.new!("session://default/team-alpha/main"),
      workspace_uri: URI.new!("workspace://team-alpha")
    }
  end
end

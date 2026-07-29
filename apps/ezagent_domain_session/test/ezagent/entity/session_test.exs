defmodule Ezagent.Entity.SessionTest do
  use ExUnit.Case, async: true
  alias Ezagent.Entity.Session

  describe "Ezagent.Kind contract" do
    test "type_name/0 returns :session" do
      assert Session.type_name() == :session
    end

    test "behaviors/0 is the chat+socialware UNION (P5-1b collapse); the two subsets select per-instance" do
      # P5-1b (socialware substrate collapse) — `Entity.Session` is the ONE
      # parameterized Session Kind; `behaviors/0` is the UNION of the chat +
      # socialware behavior sets. Templates pick the per-instance ACTIVE subset
      # via the `:kind_base` set threaded at spawn (`chat_behaviors/0` vs
      # `socialware_behaviors/0`); the P1 per-instance denial keeps a chat
      # instance from invoking the socialware-only Turn/Surface actions.
      # #189 PR-3 — every Session carries the minimal `ActionSet.SelfLicense`
      # carrier (durable principal self-license); it heads every set.
      assert Session.behaviors() == [
               Ezagent.ActionSet.SelfLicense,
               Ezagent.ActionSet.Session,
               Ezagent.ActionSet.Publisher.SessionImpl,
               Ezagent.ActionSet.ExternalMirror,
               Ezagent.ActionSet.Turn,
               Ezagent.ActionSet.Surface,
               Ezagent.ActionSet.SupervisorApproval
             ]

      assert Session.chat_behaviors() == [
               Ezagent.ActionSet.SelfLicense,
               Ezagent.ActionSet.Session,
               Ezagent.ActionSet.Publisher.SessionImpl,
               Ezagent.ActionSet.ExternalMirror
             ]

      assert Session.socialware_behaviors() == [
               Ezagent.ActionSet.SelfLicense,
               Ezagent.ActionSet.Session,
               Ezagent.ActionSet.Turn,
               Ezagent.ActionSet.Surface,
               Ezagent.ActionSet.SupervisorApproval,
               Ezagent.ActionSet.Publisher.SessionImpl
             ]
    end

    test "persistence/0 is {:snapshot, :on_change} (Allen V1 acceptance 2026-05-22)" do
      # Flipped from :ephemeral — adding an agent to a session at
      # runtime then a phx restart wiped it from members. The Session
      # Kind's Chat slice (members / last_seen / working-copy) now
      # snapshots on every change and rehydrates on (re)spawn. Same
      # mode the User Kind uses. See Ezagent.Entity.Session moduledoc.
      assert Session.persistence() == {:snapshot, :on_change}
    end
  end

  describe "default_uri/0" do
    test "returns session://system/default/main as a %URI{} struct (SPEC v3 §3.6 PR-7)" do
      uri = Session.default_uri()
      assert %URI{scheme: "session", host: "system", path: "/default/main"} = uri
    end
  end
end

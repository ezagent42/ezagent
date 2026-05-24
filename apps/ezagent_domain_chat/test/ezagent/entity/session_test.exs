defmodule Ezagent.Entity.SessionTest do
  use ExUnit.Case, async: true
  alias Ezagent.Entity.Session

  describe "Ezagent.Kind contract" do
    test "type_name/0 returns :session" do
      assert Session.type_name() == :session
    end

    test "behaviors/0 returns [Chat, Publisher.SessionImpl] — ExternalMirror PR-EM-0 added SessionImpl" do
      # SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
      # §8.1: Session implements `@behaviour Ezagent.Behavior.Publisher`
      # via the `Publisher.SessionImpl` Kind-Behavior, which owns the
      # `:publisher` slice + serves the 3 publisher actions. Added
      # alongside Chat (not nested into Chat's slice) so the Publisher
      # contract is orthogonal to chat semantics — future publisher
      # Kinds add their own SessionImpl-equivalent without touching
      # Chat.
      assert Session.behaviors() == [
               Ezagent.Behavior.Chat,
               Ezagent.Behavior.Publisher.SessionImpl
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
    test "returns session://default/default/main as a %URI{} struct (SPEC v3 §3.6 PR-7)" do
      uri = Session.default_uri()
      assert %URI{scheme: "session", host: "default", path: "/default/main"} = uri
    end
  end
end

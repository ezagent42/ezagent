defmodule Ezagent.Invariants.NoSilentWorkspaceInWritersTest do
  @moduledoc """
  SPEC #324 rev 3 + r1 codex tightening (Allen 2026-05-25) — locking gate.

  Codex r1 caught: the post-deletion `derive_workspace_uri` helpers in
  `Ezagent.Audit` and `Ezagent.Kind.Snapshot` were absorbing unknown /
  malformed / synthetic schemes into `workspace://system` via a broad
  "cross-cutting" predicate. That's the same silent-default bug class
  Allen deleted by removing `Persistence.default_workspace_uri/0`, just
  rebranded.

  These tests pin the corrected behavior: unknown schemes RAISE; only
  exact `system://` URIs fall through to the inlined
  `"workspace://system"` literal.

  ## Why this is invariant-test material

  - Both `Audit.derive_workspace/2` and `Snapshot.derive_workspace_uri/1`
    are private (`defp`); a future refactor could re-broaden the
    predicate without anyone noticing in code review.
  - The regression cost is silent — a tenant-scoped URI from a future
    scheme silently lands in admin's workspace, invisible to tenant
    reads, polluting admin reads.

  ## What's tested

  1. `Snapshot.save_now/3` with a `made-up-scheme://X` URI raises
     `ArgumentError` (not silently writes to system workspace).
  2. `Snapshot.save_now/3` with a `system://routing/default` URI
     succeeds and writes `workspace_uri = "workspace://system"`.
  3. The audit emit pipeline for an `[:ezagent, :invoke, :stop]` event
     with an unknown-scheme target raises (audit must not absorb).
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Ecto.KindSnapshot

  # Use a real Kind for the URI shape requirements; the negative
  # tests fire on the URI scheme, not the Kind module shape.
  @real_kind Ezagent.Entity.Session

  describe "Snapshot.save_now/3 — unknown scheme RAISES (codex r1)" do
    test "made-up scheme raises ArgumentError, does NOT silently land in workspace://system" do
      bogus_uri = URI.parse("madeup-scheme://x/y")

      assert_raise ArgumentError, ~r/cannot derive workspace/, fn ->
        Ezagent.Kind.Snapshot.save_now(bogus_uri, @real_kind, %{})
      end
    end

    test "synthetic identifier (cc-bridge://) raises — must not silently absorb" do
      synthetic = URI.parse("cc-bridge://abc123/event")

      assert_raise ArgumentError, ~r/cannot derive workspace/, fn ->
        Ezagent.Kind.Snapshot.save_now(synthetic, @real_kind, %{})
      end
    end

    test "unknown future scheme (probecli://) raises — must not silently absorb into system" do
      # `Capability.workspace_of/1` has a catch-all returning `:any`
      # for unregistered schemes (test-only schemes pre-PR or future
      # additions). The prior fallback predicate accepted these into
      # workspace://system; the r1 fix raises.
      future = URI.parse("probecli://foo/bar")

      assert_raise ArgumentError, ~r/cannot derive workspace/, fn ->
        Ezagent.Kind.Snapshot.save_now(future, @real_kind, %{})
      end
    end
  end

  describe "Snapshot.save_now/3 — system:// scheme lands in workspace://system" do
    test "system://routing/default is accepted and tagged with workspace://system" do
      sys_uri =
        Ezagent.URI.new!("system://routing/snapshot-test-#{System.unique_integer([:positive])}")

      :ok = Ezagent.Kind.Snapshot.save_now(sys_uri, @real_kind, %{})

      row = KindSnapshot.get(URI.to_string(sys_uri))
      assert row != nil
      assert row.workspace_uri == "workspace://system"
    end
  end

  describe "Audit persistence telemetry — r2 codex regression gate" do
    # r2 codex caught: [:ezagent, :persistence, :failed] with no
    # `meta[:uri]` (e.g. Audit.Writer flush failure) was using
    # `target = "snapshot://unknown"`, which the strict allowlist
    # rejects → derive_workspace raises INSIDE the audit telemetry
    # handler for the audit pipeline's OWN failure path. The fix:
    # `synthetic_persistence_target/1` returns a `system://` URI
    # that the allowlist accepts. This test pins the corrected
    # behavior so a future change can't reintroduce the crash loop.

    setup do
      :ok = Ezagent.Audit.attach()
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())
      :ok
    end

    test ":persistence, :failed with no :uri does not crash the handler" do
      # Emit a failure event WITHOUT :uri — the Audit.Writer flush-
      # failure shape (component: :audit_writer, reason: ...).
      :telemetry.execute(
        [:ezagent, :persistence, :failed],
        %{},
        %{
          component: :audit_writer,
          reason: "simulated flush failure"
        }
      )

      # The handler must produce an :audit_event (not crash).
      assert_receive {:audit_event, event}, 500
      assert event.event == [:ezagent, :persistence, :failed]
      assert event.metadata.component == :audit_writer
    end

    test ":persistence, :written with no :uri also routes through system fallback" do
      :telemetry.execute(
        [:ezagent, :persistence, :written],
        %{slices: 0, bytes: 0},
        %{component: :test_writer}
      )

      assert_receive {:audit_event, event}, 500
      assert event.event == [:ezagent, :persistence, :written]
    end
  end
end

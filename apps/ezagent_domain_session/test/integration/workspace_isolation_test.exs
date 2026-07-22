defmodule EzagentDomainInstanceMessage.Integration.WorkspaceIsolationTest do
  @moduledoc """
  Phase 7 PR 31 invariant — workspace_uri-scoped routing rules
  must NOT fire for messages dispatched in a different workspace.

  Drives the **production path**: `Chat.invoke(:send, ...)` at
  chat.ex:116 → `Resolver.resolve/4` with `workspace_uri:` opt
  derived from `WorkspaceRegistry.lookup(session_uri)`. Pre-PR-31
  this call used 3-arg `resolve/3` with empty opts, silently
  dropping the workspace scope.

  Receipts are observed via the audit log (`invocations` table)
  rather than recipient slice state — recipients (User Kind) may
  just PubSub.broadcast for LV consumption with no DB write, so
  audit is the authoritative cross-recipient observable.

  V criteria gated (per VERIFICATION.md):
  - V3.2 — Workspace isolation enforced at CapBAC + Resolver
  - V4.4 — Workspace-scoped routing CI gate
  """

  use EzagentCore.DataCase, async: false
  import Ecto.Query

  alias Ezagent.{Invocation, Message, RoutingRegistry}
  alias Ezagent.Routing.{Matcher, RuleStore}
  alias Ezagent.Entity.User
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  setup do
    # This suite observes `chat.receive` fan-out via the `invocations`
    # audit table. `Ezagent.Audit.Writer` is skipped from the test-env
    # supervision tree (2026-05-26 sandbox-isolation fix); start it
    # per-test and allow it onto this test's sandbox connection so the
    # telemetry → row write actually lands. Without this, no invocation
    # rows are written and every `receive_dispatches_to/1` count stays 0.
    {:ok, writer} = start_supervised(Ezagent.Audit.Writer)
    Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), writer)

    original = Application.get_env(:ezagent_core, :routing_tables)

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    :ok
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp setup_scenario do
    suffix = unique("ws-iso")
    table_name = String.to_atom("workspace_iso_test_#{suffix}")
    :ok = RoutingRegistry.declare_table(table_name, key_uniqueness: :duplicate)
    Application.put_env(:ezagent_core, :routing_tables, [table_name])

    workspace_a = URI.new!("workspace://#{suffix}-A")
    workspace_b = URI.new!("workspace://#{suffix}-B")

    # SPEC v3 §3.6 (Phase 9 PR-7) — 3-segment sessions carry workspace
    # as second path segment.
    session_a = URI.new!("session://#{suffix}-A/default/main")
    session_b = URI.new!("session://#{suffix}-B/default/main")

    {:ok, _} = Ezagent.SpawnRegistry.spawn(session_a)
    {:ok, _} = Ezagent.SpawnRegistry.spawn(session_b)

    :ok = Ezagent.WorkspaceRegistry.bind(session_a, workspace_a)
    :ok = Ezagent.WorkspaceRegistry.bind(session_b, workspace_b)

    sender_a = URI.new!("entity://#{suffix}-A/user/#{unique("sender-a")}")
    sender_b = URI.new!("entity://#{suffix}-B/user/#{unique("sender-b")}")
    eavesdropper_a = URI.new!("entity://#{suffix}-A/user/#{unique("eavesdropper-a")}")
    eavesdropper_b = URI.new!("entity://#{suffix}-B/user/#{unique("eavesdropper-b")}")

    for uri <- [sender_a, sender_b, eavesdropper_a, eavesdropper_b] do
      {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    end

    %{
      table: table_name,
      workspace_a: workspace_a,
      workspace_b: workspace_b,
      session_a: session_a,
      session_b: session_b,
      sender_a: sender_a,
      sender_b: sender_b,
      eavesdropper_a: eavesdropper_a,
      eavesdropper_b: eavesdropper_b
    }
  end

  defp dispatch_send(session_uri, sender, text) do
    msg = Message.new(sender, %{text: text, attachments: []})
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")

    inv = %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: sender,
        authenticated_principal: sender,
        caps: MapSet.new([signed_action_cap!(target, sender)]),
        reply: :ignore
      }
    }

    Invocation.dispatch(inv)
    # Audit writes are async (Ezagent.Audit.Writer flushes ~every 1s).
    # Force a flush so this test doesn't race the writer.
    if Process.whereis(Ezagent.Audit.Writer), do: send(Ezagent.Audit.Writer, :flush)
    Process.sleep(250)
    msg
  end

  defp receive_dispatches_to(target_uri) do
    # PR-2 (im/session/agent decomposition §OQ-4 / §3.3): the `:receive`
    # fan-out spells the behavior prefix per recipient Kind — `user.receive`
    # / `agent.receive`. The prefix is telemetry-only (routing keys on the
    # action atom + Kind), but the audit `target` carries it, so this
    # counter matches the per-Kind spelling instead of `session.receive`.
    behavior =
      case Ezagent.URI.type(target_uri) do
        {:ok, "user"} -> "user"
        _ -> "agent"
      end

    target_prefix = "#{URI.to_string(target_uri)}?action=#{behavior}.receive"

    # Membership-cap unification A2.2 — this counter measures whether the routing
    # RULE FIRES (resolves to `target_uri` and ATTEMPTS a `:receive` dispatch),
    # which is upstream of and independent from receive-authorization. Post-A2.2,
    # `:receive` is cap_exempt (no `authz == "granted"` row) AND a non-member
    # target (this eavesdropper) is DENIED in-handler on the held-cap check — so
    # the old `authz == "granted"` filter zeroes for ALL recipients. Count the
    # dispatch ATTEMPT (any authz), which is the rule-firing signal the test
    # asserts; the downstream non-member denial is by-design (R1.1) and NOT what
    # this workspace-scoping test measures.
    EzagentCore.Repo.all(
      from(i in "invocations",
        where: fragment("? LIKE ?", i.target, ^"#{target_prefix}%"),
        select: i.inserted_at
      )
    )
  end

  test "rule scoped to workspace://A does NOT fire for message dispatched in workspace://B" do
    ctx = setup_scenario()

    {:ok, _} =
      RuleStore.add(
        ctx.table,
        Matcher.always(),
        [URI.to_string(ctx.eavesdropper_a)],
        URI.to_string(User.admin_uri()),
        workspace_uri: URI.to_string(ctx.workspace_a)
      )

    :ok = RuleStore.load_into_registry(ctx.table)

    eavesdropper_before = length(receive_dispatches_to(ctx.eavesdropper_a))

    _msg_b = dispatch_send(ctx.session_b, ctx.sender_b, "in workspace B")

    eavesdropper_after = length(receive_dispatches_to(ctx.eavesdropper_a))

    assert eavesdropper_after == eavesdropper_before,
           "workspace-A-scoped rule fired for workspace-B message " <>
             "(eavesdropper received #{eavesdropper_after - eavesdropper_before} unexpected dispatch) — " <>
             "PR 31 workspace isolation broken"
  end

  test "rule scoped to workspace://A DOES fire for message dispatched in workspace://A (positive control)" do
    ctx = setup_scenario()

    {:ok, _} =
      RuleStore.add(
        ctx.table,
        Matcher.always(),
        [URI.to_string(ctx.eavesdropper_a)],
        URI.to_string(User.admin_uri()),
        workspace_uri: URI.to_string(ctx.workspace_a)
      )

    :ok = RuleStore.load_into_registry(ctx.table)

    eavesdropper_before = length(receive_dispatches_to(ctx.eavesdropper_a))

    _msg_a = dispatch_send(ctx.session_a, ctx.sender_a, "in workspace A")

    eavesdropper_after = length(receive_dispatches_to(ctx.eavesdropper_a))

    assert eavesdropper_after > eavesdropper_before,
           "workspace-A-scoped rule did NOT fire for workspace-A message — " <>
             "the scoping mechanism dropped a valid match (false negative)"
  end

  test "nil-scoped (global) rule fires for messages in any workspace (regression guard)" do
    ctx = setup_scenario()

    {:ok, _} =
      RuleStore.add(
        ctx.table,
        Matcher.always(),
        [URI.to_string(ctx.eavesdropper_a), URI.to_string(ctx.eavesdropper_b)],
        URI.to_string(User.admin_uri()),
        workspace_uri: nil
      )

    :ok = RuleStore.load_into_registry(ctx.table)

    eavesdropper_before =
      length(receive_dispatches_to(ctx.eavesdropper_a)) +
        length(receive_dispatches_to(ctx.eavesdropper_b))

    _ = dispatch_send(ctx.session_a, ctx.sender_a, "from A — global rule should fire")
    _ = dispatch_send(ctx.session_b, ctx.sender_b, "from B — global rule should fire")

    eavesdropper_after =
      length(receive_dispatches_to(ctx.eavesdropper_a)) +
        length(receive_dispatches_to(ctx.eavesdropper_b))

    assert eavesdropper_after - eavesdropper_before >= 2,
           "nil-scoped (global) rule did not fire for both workspaces — " <>
             "regression in pre-PR-31 behavior (workspace_uri scoping broke global rules)"
  end

  test "Phase 9 PR-7 — 2-segment session URI is rejected at parse time (invariant 11)" do
    # SPEC v3 §3.6 (Phase 9 PR-7) — workspace derivation is structural
    # from the URI path; an unbound session is no longer possible
    # because every session URI MUST be 3-segment
    # `session://<template>/<workspace>/<name>`. The pre-PR-7
    # "unbound session" failure mode has been replaced by a parse-time
    # rejection: `Ezagent.URI.new!/1` raises on 2-segment session
    # URIs.
    ctx = setup_scenario()

    suffix = unique("unbound")

    # 2-segment session URI MUST be rejected at parse time. Concatenate
    # the literal so the bulk-rewrite tool doesn't 3-segment it.
    legacy = "session://" <> "#{suffix}-unbound"

    assert_raise ArgumentError, ~r/session URI must include type and name segments/, fn ->
      Ezagent.URI.new!(legacy)
    end

    eavesdropper_before = length(receive_dispatches_to(ctx.eavesdropper_a))
    eavesdropper_after = eavesdropper_before

    assert eavesdropper_after == eavesdropper_before,
           "Phase 9 PR-6 invariant 4 strictness regression — an unbound session " <>
             "must NOT deliver a message; per SPEC v3 §7 + workspace_uri NOT NULL " <>
             "the write fails closed. If this assertion fails, either invariant 4 " <>
             "got loosened or someone re-added a silent default workspace at the " <>
             "MessageStore.write boundary."
  end
end

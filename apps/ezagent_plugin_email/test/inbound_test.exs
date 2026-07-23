defmodule Ezagent.Email.InboundTest do
  @moduledoc """
  #88 PR-2 (SPEC §4.5 / §4.5b / §4.6 / §7) — the inbound poll pipeline:
  address resolution, verification + auth gate, deterministic dedup,
  inject-under-restricted-participant, DELETE-after-inject, loop guard.

  The dispatch + delete seams are injected so the test need not boot a live
  Session Kind. The dedup test asserts the deterministic id is STABLE across
  re-deliveries (same id → `MessageStore`'s `on_conflict: :nothing` no-ops the
  second write); the no-op insert itself is a property of the already-verified
  `MessageStore.write` path, not re-exercised here through the mocked dispatch.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Email.{Inbound, InboundBinding}
  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentCore.Repo

  @target "human@example.com"
  @ws "workspace://system"
  @alias "inbox-alias@ezagent.chat"

  setup do
    cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)
    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, cap_config) end)
    :ok
  end

  # Create a verified email binding (parent row + email-meta row) for a fresh
  # session. Returns {session_uri, binding_row_id}.
  defp verified_binding!(local_address \\ @alias, target \\ @target) do
    session_uri =
      Ezagent.URI.new!("session://system/default/in-#{System.unique_integer([:positive])}")

    row_id = BindingRow.row_id(session_uri, "email", target)

    {:ok, _} =
      BindingRow.insert(%{
        id: row_id,
        session_uri: URI.to_string(session_uri),
        adapter_id: "email",
        target_id: target,
        opts_json: "{}",
        bound_by: "entity://system/user/admin",
        bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        workspace_uri: @ws
      })

    {:ok, {_, _}} =
      InboundBinding.record(%{
        binding_row_id: row_id,
        local_address: local_address,
        session_uri: URI.to_string(session_uri),
        target_id: target,
        workspace_uri: @ws
      })

    {:ok, _} = InboundBinding.mark_verified(row_id)

    {session_uri, row_id}
  end

  defp rec(local_address, overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "inbox:k-#{System.unique_integer([:positive])}",
        "to" => local_address,
        "from" => @target,
        "text" => "human reply text",
        "messageId" => "<human-#{System.unique_integer([:positive])}@mail.example.com>",
        "returnPath" => @target,
        "autoSubmitted" => "no",
        "precedence" => "",
        "authResults" => "spf=pass dkim=pass dmarc=pass"
      },
      overrides
    )
  end

  # A test harness collecting dispatched invocations + deleted keys into the
  # current process via an Agent.
  defp harness do
    {:ok, agent} = Agent.start_link(fn -> %{dispatched: [], deleted: []} end)

    dispatch_fun = fn inv ->
      Agent.update(agent, fn s -> %{s | dispatched: [inv | s.dispatched]} end)
      {:ok, %{stored: true}}
    end

    delete_fun = fn key ->
      Agent.update(agent, fn s -> %{s | deleted: [key | s.deleted]} end)
      :ok
    end

    {agent, [dispatch_fun: dispatch_fun, delete_fun: delete_fun]}
  end

  defp dispatched(agent), do: Agent.get(agent, & &1.dispatched)
  defp deleted(agent), do: Agent.get(agent, & &1.deleted)

  describe "process_record/2 — happy path" do
    test "injects a verified, authenticated reply and deletes after inject" do
      {_su, _row_id} = verified_binding!()
      {agent, opts} = harness()
      r = rec(@alias)

      assert {:injected, msg_id} = Inbound.process_record(r, opts)
      assert is_binary(msg_id)

      [inv] = dispatched(agent)
      assert inv.mode == :call
      assert %URI{scheme: "entity"} = inv.ctx.caller
      assert inv.ctx.authenticated_principal == Ezagent.Entity.User.admin_uri()
      refute inv.ctx.caller == inv.ctx.authenticated_principal
      assert MapSet.size(inv.ctx.caps) == 1
      # self-echo guard stamp present
      assert inv.args.message.body._email_origin == true
      assert inv.args.message.body.text == "human reply text"

      # DELETE happened, AFTER inject (key recorded)
      assert deleted(agent) == [r["key"]]
    end
  end

  describe "deterministic dedup (§4.5b)" do
    test "two polls of the same email inject ONE message (same deterministic id)" do
      {su, _row_id} = verified_binding!()
      {_agent, opts} = harness()
      mid = "<dup-#{System.unique_integer([:positive])}@mail.example.com>"
      r = rec(@alias, %{"messageId" => mid})

      {:injected, id1} = Inbound.process_record(r, opts)
      # second delivery — same Message-ID + session → same id
      {:injected, id2} = Inbound.process_record(Map.put(r, "key", "inbox:other"), opts)

      assert id1 == id2
      assert id1 == Inbound.deterministic_id(su, mid)
    end
  end

  describe "auth + verification gates (BLOCKER 2) — reject + DELETE, no inject" do
    test "DMARC fail → rejected, deleted, not injected" do
      {_su, _} = verified_binding!()
      {agent, opts} = harness()
      r = rec(@alias, %{"authResults" => "spf=fail dkim=fail dmarc=fail"})

      assert {:skipped, :auth_failed} = Inbound.process_record(r, opts)
      assert dispatched(agent) == []
      assert deleted(agent) == [r["key"]]
    end

    test "From mismatch (forged) → rejected, deleted" do
      {_su, _} = verified_binding!()
      {agent, opts} = harness()
      r = rec(@alias, %{"from" => "attacker@evil.example.com"})

      assert {:skipped, :from_mismatch} = Inbound.process_record(r, opts)
      assert dispatched(agent) == []
      assert deleted(agent) == [r["key"]]
    end

    test "unverified binding → rejected, deleted" do
      session_uri =
        Ezagent.URI.new!("session://system/default/in-unv-#{System.unique_integer([:positive])}")

      row_id = BindingRow.row_id(session_uri, "email", @target)

      {:ok, _} =
        BindingRow.insert(%{
          id: row_id,
          session_uri: URI.to_string(session_uri),
          adapter_id: "email",
          target_id: @target,
          opts_json: "{}",
          bound_by: "entity://system/user/admin",
          bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          workspace_uri: @ws
        })

      {:ok, {_, _}} =
        InboundBinding.record(%{
          binding_row_id: row_id,
          local_address: "unverified-alias@ezagent.chat",
          session_uri: URI.to_string(session_uri),
          target_id: @target,
          workspace_uri: @ws
        })

      # NOT marked verified.
      {agent, opts} = harness()
      r = rec("unverified-alias@ezagent.chat")

      assert {:skipped, :not_verified} = Inbound.process_record(r, opts)
      assert dispatched(agent) == []
      assert deleted(agent) == [r["key"]]
    end

    test "unknown alias → rejected, deleted" do
      {agent, opts} = harness()
      r = rec("nobody@ezagent.chat")

      assert {:skipped, :no_binding} = Inbound.process_record(r, opts)
      assert dispatched(agent) == []
      assert deleted(agent) == [r["key"]]
    end

    test "unbind cascades the projection → rejected, deleted" do
      {_session_uri, row_id} = verified_binding!()
      assert {:ok, :deleted} = BindingRow.delete_by_id(row_id)
      assert Repo.get(InboundBinding, row_id) == nil

      {agent, opts} = harness()
      r = rec(@alias)

      assert {:skipped, :no_binding} = Inbound.process_record(r, opts)
      assert dispatched(agent) == []
      assert deleted(agent) == [r["key"]]
    end
  end

  describe "loop guard (MED 8) — reject + DELETE, no inject" do
    test "bounce (empty envelope-from) rejected before auth" do
      {_su, _} = verified_binding!()
      {agent, opts} = harness()
      r = rec(@alias, %{"returnPath" => "<>"})

      assert {:skipped, :bounce} = Inbound.process_record(r, opts)
      assert dispatched(agent) == []
      assert deleted(agent) == [r["key"]]
    end

    test "auto-reply rejected" do
      {_su, _} = verified_binding!()
      {agent, opts} = harness()
      r = rec(@alias, %{"autoSubmitted" => "auto-replied"})

      assert {:skipped, :auto_submitted} = Inbound.process_record(r, opts)
      assert dispatched(agent) == []
    end
  end

  describe "inject failure → NOT deleted (retry on next poll)" do
    test "a dispatch error retains the inbox item" do
      {_su, _} = verified_binding!()
      {:ok, agent} = Agent.start_link(fn -> %{deleted: []} end)

      dispatch_fun = fn _inv -> {:error, :unauthorized} end

      delete_fun = fn key ->
        Agent.update(agent, fn s -> %{s | deleted: [key | s.deleted]} end)
      end

      opts = [dispatch_fun: dispatch_fun, delete_fun: delete_fun]
      r = rec(@alias)

      assert {:error, :unauthorized} = Inbound.process_record(r, opts)
      assert Agent.get(agent, & &1.deleted) == []
    end

    test "an authority reader failure retains the inbox item" do
      {agent, opts} = harness()
      authority_fun = fn _record -> {:retry, {:binding_reader_failed, :unavailable}} end
      r = rec("reader-failure@ezagent.chat")

      assert {:error, {:binding_reader_failed, :unavailable}} =
               Inbound.process_record(r, Keyword.put(opts, :authority_fun, authority_fun))

      assert dispatched(agent) == []
      assert deleted(agent) == []
    end

    test "a capability authority failure retains the inbox item" do
      {su, _row_id} = verified_binding!()
      {:ok, _pid} = Ezagent.LocalRuntime.ensure_started(su)
      :ok = Ezagent.Cap.Authority.retire(su)
      {agent, opts} = harness()
      r = rec(@alias)

      assert {:error, {:cap_issue_failed, _reason}} =
               Inbound.process_record(r, opts)

      assert dispatched(agent) == []
      assert deleted(agent) == []
    end
  end

  describe "binding provenance join" do
    test "a corrupt email projection cannot borrow authority from an unrelated binding" do
      session_uri =
        Ezagent.URI.new!(
          "session://system/default/in-corrupt-#{System.unique_integer([:positive])}"
        )

      row_id = BindingRow.row_id(session_uri, "slack", "unrelated-target")

      assert {:ok, _row} =
               BindingRow.insert(%{
                 id: row_id,
                 session_uri: URI.to_string(session_uri),
                 adapter_id: "slack",
                 target_id: "unrelated-target",
                 opts_json: "{}",
                 bound_by: "entity://system/user/admin",
                 bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
                 workspace_uri: @ws
               })

      local_address = "corrupt-#{System.unique_integer([:positive])}@ezagent.chat"

      assert {:ok, {_, _token}} =
               InboundBinding.record(%{
                 binding_row_id: row_id,
                 local_address: local_address,
                 session_uri: URI.to_string(session_uri),
                 target_id: @target,
                 workspace_uri: "workspace://wrong"
               })

      assert {:ok, _row} = InboundBinding.mark_verified(row_id)
      {agent, opts} = harness()

      assert {:skipped, :binding_authority_mismatch} =
               Inbound.process_record(rec(local_address), opts)

      assert dispatched(agent) == []
      assert deleted(agent) != []
    end
  end
end

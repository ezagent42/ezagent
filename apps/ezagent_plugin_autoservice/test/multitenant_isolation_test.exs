defmodule EzagentPluginAutoservice.MultitenantIsolationTest do
  @moduledoc """
  Multi-tenant isolation proof — two tenants provisioned in one test env via
  dev's REAL provisioning path (`CustomerSession.provision/2`).

  Ported from PR #731's `multitenant_test.exs`, adapted to autoservice-dev's
  provisioning surface (which uses `CustomerSession.provision/2` rather than
  the older `Assembly.provision_session/4` + `TurnDriver`). The two tenants are
  `cinnox`/`alice` and `acme`/`bob`. Each tenant is stood up exactly the way
  `mix ezagent.demo.seed_autoservice` does it:

    1. `Ezagent.Workspace.create(tid, ...)`            -- the workspace Kind
    2. `Ezagent.Users.create(customer_uri, pw,         -- the customer User row
        Roles.bundle(:customer, ws))`                     (default + role caps,
                                                           all workspace-scoped)
    3. grant those role caps via `identity.grant_cap`  -- land them in the slice
    4. `CustomerSession.provision(customer_uri,        -- fast agent + session +
        tid:, workspace_uri:, ctx:, with_slow: false,     routing + greeting
        deepseek_key: nil)`

  `with_slow: false` + `deepseek_key: nil` means NO real AI agents are spawned
  (the fast agent is created as a `curl.agent` template with no key — it never
  produces a reply). We assert isolation, not replies.

  The privileged setup ctx mirrors the seed task: `caller = system://mix-task`,
  `caps = SystemPrincipal.caps("system://mix-task")`.

  Asserts:
  1. Session URIs are tenant-namespaced (cinnox vs acme) under distinct workspaces.
  2. A customer-visible message settled into alice's session does NOT appear in
     bob's gated `CustomerFeed` (and the reverse).
  3. Routing rows are session-scoped: acme's matcher carries bob's session URI
     and never matches alice's session (and the reverse).
  4. Alice (cinnox customer) holds NO cap scoped to acme's workspace.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Identity
  alias Ezagent.Invocation
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginAutoservice.{CustomerSession, Roles, Uris}

  @routing_table EzagentDomainInstanceMessage.Routing.MentionRouting

  # Privileged seed principal — same as `mix ezagent.demo.seed_autoservice`.
  defp priv_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("mix-task"),
      caps: Ezagent.SystemPrincipal.caps("system://mix-task")
    }
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  # Stand up one tenant exactly as the seed task does: workspace -> user (with
  # workspace-scoped customer role caps) -> grant caps into the slice ->
  # provision the customer-service session (fast agent + routing + greeting).
  defp provision_tenant(tid, customer_name, ctx) do
    workspace_uri = Ezagent.URI.workspace(tid)
    customer_uri = Ezagent.URI.user(tid, customer_name)

    {:ok, _} = ensure_workspace(tid)

    # `Ezagent.Users.create/3` persists `default_caps(ws) ++ role_caps` into the
    # `users.caps_json` column. The customer's User Kind is spawned later by
    # `CustomerSession.provision` (`ensure_user_alive`), and `Identity.activate/2`
    # re-reads `caps_json` and unions it into the slice — so we don't need the
    # seed task's explicit `identity.grant_cap` dispatch (that loop exists only
    # to bridge the seed VM -> phx.server VM atom boundary, which doesn't apply
    # in-VM here).
    role_caps = Roles.bundle(:customer, workspace_uri)
    {:ok, _decoded} = Ezagent.Users.create(customer_uri, customer_name, role_caps)

    {:ok, info} =
      CustomerSession.provision(customer_uri,
        tid: tid,
        workspace_uri: workspace_uri,
        ctx: ctx,
        deepseek_key: nil,
        with_slow: false
      )

    %{
      tid: tid,
      customer_uri: customer_uri,
      workspace_uri: workspace_uri,
      session_uri: info.session_uri,
      fast_uri: info.fast_uri,
      slow_uri: info.slow_uri,
      token: CustomerAuth.issue_token(info.session_uri, workspace_uri)
    }
  end

  defp ensure_workspace(tid) do
    case Ezagent.Workspace.create(tid, %{}) do
      {:ok, pid} -> {:ok, pid}
      {:error, :workspace_exists} -> {:ok, :exists}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # Drive a customer-visible turn into a session and return the answer text.
  # open -> compose(:chat) -> settle commits the message customer_visible, so it
  # lands in the gated CustomerFeed (the no-leak path operator_takeover proves).
  defp drive_customer_visible_turn(session_uri, text, ctx) do
    turn = fn action, args ->
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.#{action}"),
        mode: :call,
        args: args,
        ctx: Map.put(ctx, :reply, {:caller_inbox, self()})
      })
    end

    {:ok, %{turn_id: turn_id}} =
      turn.(:open, %{
        trigger: %{message_id: "mt-#{System.unique_integer([:positive])}"},
        opened_at: 1
      })

    {:ok, _} = turn.(:compose, %{turn_id: turn_id, result_refs: [%{kind: :chat, text: text}]})
    {:ok, %{status: :settled}} = turn.(:settle, %{turn_id: turn_id})
    :ok
  end

  defp feed_texts(session_uri, token) do
    {:ok, %{messages: messages}} = CustomerFeed.snapshot(session_uri, token)
    Enum.map(messages, fn m -> m.body[:text] || m.body["text"] end)
  end

  setup do
    # The fast agent is a `curl.agent` workspace template; that template class is
    # registered by `:ezagent_plugin_curl_agent` at app start. The seed task starts
    # it explicitly (`Application.ensure_all_started(:ezagent_plugin_curl_agent)`),
    # and so must we — autoservice doesn't hard-depend on it, so the test env
    # doesn't auto-start it.
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)

    suffix = System.unique_integer([:positive])
    cinnox_tid = "cinnox#{suffix}"
    acme_tid = "acme#{suffix}"
    ctx = priv_ctx()

    cinnox = provision_tenant(cinnox_tid, "alice", ctx)
    acme = provision_tenant(acme_tid, "bob", ctx)

    %{cinnox: cinnox, acme: acme, ctx: ctx}
  end

  # ---------------------------------------------------------------------------
  # 1. Session URIs are under distinct workspaces
  # ---------------------------------------------------------------------------

  describe "session URI isolation" do
    test "alice's session is under cinnox, bob's under acme — distinct", %{
      cinnox: cinnox,
      acme: acme
    } do
      assert URI.to_string(cinnox.session_uri) ==
               "session://#{cinnox.tid}/#{Uris.session_class()}/alice"

      assert URI.to_string(acme.session_uri) ==
               "session://#{acme.tid}/#{Uris.session_class()}/bob"

      # Each session is under its own workspace.
      assert cinnox.session_uri.host == cinnox.workspace_uri.host
      assert acme.session_uri.host == acme.workspace_uri.host

      refute cinnox.session_uri == acme.session_uri
      refute cinnox.workspace_uri == acme.workspace_uri
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Message isolation — alice's message does not appear in bob's feed
  # ---------------------------------------------------------------------------

  describe "message isolation" do
    test "alice's settled message never appears in bob's CustomerFeed (and reverse)", %{
      cinnox: cinnox,
      acme: acme,
      ctx: ctx
    } do
      alice_text = "alice says hi #{System.unique_integer([:positive])}"
      bob_text = "bob says hi #{System.unique_integer([:positive])}"

      :ok = drive_customer_visible_turn(cinnox.session_uri, alice_text, ctx)
      :ok = drive_customer_visible_turn(acme.session_uri, bob_text, ctx)

      # Each message lands in its OWN feed (sanity — the message really exists).
      wait_until(fn -> alice_text in feed_texts(cinnox.session_uri, cinnox.token) end)
      wait_until(fn -> bob_text in feed_texts(acme.session_uri, acme.token) end)

      # Cross-tenant: bob's feed never sees alice's message, and vice versa.
      refute alice_text in feed_texts(acme.session_uri, acme.token),
             "bob's CustomerFeed leaked alice's message: " <>
               inspect(feed_texts(acme.session_uri, acme.token))

      refute bob_text in feed_texts(cinnox.session_uri, cinnox.token),
             "alice's CustomerFeed leaked bob's message: " <>
               inspect(feed_texts(cinnox.session_uri, cinnox.token))
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Routing row isolation — matcher carries the specific session URI
  # ---------------------------------------------------------------------------

  describe "routing isolation" do
    test "acme's routing matcher carries bob's session and never matches cinnox", %{
      cinnox: cinnox,
      acme: acme
    } do
      assert_session_scoped(acme, cinnox)
    end

    test "cinnox's routing matcher carries alice's session and never matches acme", %{
      cinnox: cinnox,
      acme: acme
    } do
      assert_session_scoped(cinnox, acme)
    end
  end

  # CsOrchestrator routing: receivers = [orch_receiver] where orch_receiver
  # is session?action=cs_orchestrator.process_message. Look for the
  # cs_orchestrator action in receivers (not direct agent URIs).
  defp assert_session_scoped(self_tenant, other_tenant) do
    self_session = URI.to_string(self_tenant.session_uri)
    other_session = URI.to_string(other_tenant.session_uri)

    rules = Ezagent.Routing.RuleStore.list(@routing_table)
    self_rules =
      Enum.filter(rules, fn r ->
        Enum.any?(r.receivers || [], fn recv ->
          String.contains?(recv, "cs_orchestrator.process_message") and
            String.contains?(recv, self_session)
        end)
      end)

    assert length(self_rules) >= 1,
           "expected >=1 routing rule with cs_orchestrator.process_message for #{self_tenant.tid}"

    Enum.each(self_rules, fn rule ->
      matcher_str = matcher_to_string(rule.matcher_data)

      assert String.contains?(matcher_str, self_session),
             "#{self_tenant.tid} routing matcher should reference its session " <>
               "#{self_session}; got: #{matcher_str}"

      refute String.contains?(matcher_str, other_session),
             "#{self_tenant.tid} routing matcher must NOT reference the other tenant's " <>
               "session #{other_session}; got: #{matcher_str}"
    end)
  end

  defp matcher_to_string(s) when is_binary(s), do: s
  defp matcher_to_string(m) when is_map(m), do: Jason.encode!(m)
  defp matcher_to_string(other), do: inspect(other)

  # ---------------------------------------------------------------------------
  # 4. Cap isolation — a customer holds NO cap scoped to the OTHER workspace
  # ---------------------------------------------------------------------------

  describe "cap isolation" do
    test "alice's caps are scoped only to cinnox workspace (never acme)", %{
      cinnox: cinnox,
      acme: acme
    } do
      alice_caps = Identity.list_caps_for(cinnox.customer_uri)

      acme_scoped =
        alice_caps
        |> Enum.filter(fn cap -> cap.workspace_uri == acme.workspace_uri end)

      assert acme_scoped == [],
             "alice must hold NO cap scoped to acme workspace " <>
               "#{URI.to_string(acme.workspace_uri)}; found: #{inspect(acme_scoped)}"

      # Positive: alice DOES hold session-kind caps scoped to cinnox.
      cinnox_session_caps =
        alice_caps
        |> Enum.filter(fn cap ->
          cap.kind == :session and cap.workspace_uri == cinnox.workspace_uri
        end)

      refute cinnox_session_caps == [],
             "alice should hold session caps scoped to cinnox; all: #{inspect(MapSet.to_list(alice_caps))}"
    end

    test "bob's caps are scoped only to acme workspace (never cinnox)", %{
      cinnox: cinnox,
      acme: acme
    } do
      bob_caps = Identity.list_caps_for(acme.customer_uri)

      cinnox_scoped =
        bob_caps
        |> Enum.filter(fn cap -> cap.workspace_uri == cinnox.workspace_uri end)

      assert cinnox_scoped == [],
             "bob must hold NO cap scoped to cinnox workspace " <>
               "#{URI.to_string(cinnox.workspace_uri)}; found: #{inspect(cinnox_scoped)}"
    end
  end
end

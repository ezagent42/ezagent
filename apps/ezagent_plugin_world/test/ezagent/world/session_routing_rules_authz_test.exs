defmodule Ezagent.World.SessionRoutingRulesAuthzTest do
  @moduledoc """
  P2 test-supplement — `Ezagent.World.ConversationActions.add_routing_rule/3`
  and `toggle_routing_rule/3` (the `session.routing.add` / `session.routing.toggle`
  dispatch handlers) had no behavior test. Session mention-routing rules are a
  governance surface (they redirect where messages get delivered inside a
  session), so who may add/toggle them is a real authz edge, on par with
  member invite/remove.

  ## BUG FOUND (reported, NOT fixed — out of this test-supplement's scope per
  the "no product-code changes unless a test finds a real bug, then STOP that
  item" rule)

  `dispatch_session_routing/4` (private, `conversation_actions.ex`) hardcodes
  `caps: MapSet.new()` in the dispatch ctx instead of threading the caller's
  real caps (`Ezagent.World.PresenterCaps.load(socket)` — the pattern EVERY
  other dispatch function in this same file uses, and the pattern the OTHER
  production caller of this exact `:routing`/`:add_rule` target
  (`Ezagent.Orchestrator.Tools.define_rule_set_rule/3`, `ctx(caller, caps)`)
  correctly follows). The empty cap set means the CapBAC chokepoint
  (`Ezagent.Cap.Verifier`) can NEVER find a matching cap for ANY caller,
  however legitimately authorized — `session.routing.add` and
  `session.routing.toggle` currently return `error:missing_cap` for EVERY
  caller, including one holding the exact required signed cap. This was
  discovered empirically: a test asserting the positive path (a capped owner
  successfully adds a rule) failed with `"error:missing_cap"` even after
  minting + durably granting the caller the precise `:routing`/`:add_rule`
  cap the target action declares.

  Net effect: the world UI's session-routing-rule add/enable/disable feature
  is currently DEAD for every caller (fail-closed, not a leak — no
  unauthorized rule is ever created either, since nobody can create one) —
  a functional regression, not a security hole. `session_routing_add_rule_missing_cap_bug_test`
  below pins the CURRENT (buggy) behavior as a regression trap: it goes GREEN
  the moment someone threads real caps into `dispatch_session_routing/4` and
  should be flipped to assert `"ok"` at that point.

  What THIS file still pins for real, independent of that bug:

    * an OUTSIDER with zero caps cannot add a rule and nothing leaks/persists
      (true today, though for the "everyone is denied" reason above rather
      than a narrowly-scoped authz distinction — still a valid fail-closed
      guarantee to regression-lock).
    * a malformed matcher FORM is rejected BEFORE any dispatch is attempted
      (pure validation, unaffected by the caps bug).
    * a bad rule id on toggle degrades to `error:bad_rule_id` before dispatch
      (same — pure validation short-circuit).
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.Capability
  alias Ezagent.World.{ConversationActions, ConversationData}

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    :ok
  end

  defp uniq, do: System.unique_integer([:positive])
  defp new_ws, do: "wrouting-#{uniq()}"

  defp confirmed_user(ws, prefix) do
    uri = URI.new!("entity://#{ws}/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp new_session(owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "routing-conv-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  # Explicitly sign + durably grant the exact `:routing`/`action` cap — same
  # robust pattern as `remove_participant_authz_test.exs`'s `socket_with_cap/3`
  # (doesn't rely on whatever `SessionCreator` grants the owner by default).
  defp socket_with_routing_cap(caller, session_uri, action) do
    target = Ezagent.URI.with_action(session_uri, :routing, action)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)
    :ok = Ezagent.EntityCaps.grant(caller, cap)

    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, Capability.workspace_of(caller))
    |> assign(:last_dispatch_status, "idle")
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
  end

  defp bare_socket(caller) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, Capability.workspace_of(caller))
    |> assign(:last_dispatch_status, "idle")
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
  end

  # `matcher_type: "mention"`/`"from"` route `matcher_arg` through URI
  # revalidation (`revalidate_matcher_arg/2` — it must itself be a valid
  # entity URI, an @mention reference). `"text_contains"` needs no such
  # validation, so a plain keyword avoids coupling this fixture to that
  # unrelated URI-revalidation path.
  defp text_rule_params(receiver_uri) do
    %{
      "matcher_type" => "text_contains",
      "matcher_arg" => "help",
      "receivers" => URI.to_string(receiver_uri)
    }
  end

  test "BUG regression trap: even a caller holding the exact required cap is denied (error:missing_cap)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session_uri = new_session(owner)

    {:noreply, out} =
      ConversationActions.handle_dispatch(
        socket_with_routing_cap(owner, session_uri, :add_rule),
        "session.routing.add",
        %{"session_uri" => URI.to_string(session_uri), "rule" => text_rule_params(owner)}
      )

    # Pins the CURRENT (buggy) behavior — see moduledoc. If this assertion
    # ever fails because the status became "ok", `dispatch_session_routing/4`
    # was fixed to thread real caps: flip this test to assert success and
    # move it out of the "BUG" section.
    assert out.assigns.last_dispatch_status == "error:missing_cap"
    assert ConversationData.list_session_routing_rules(session_uri) == []
  end

  test "an OUTSIDER with zero caps cannot add a rule; nothing leaks or persists" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    outsider = confirmed_user(ws, "outsider")
    session_uri = new_session(owner)

    {:noreply, out} =
      ConversationActions.handle_dispatch(
        bare_socket(outsider),
        "session.routing.add",
        %{"session_uri" => URI.to_string(session_uri), "rule" => text_rule_params(owner)}
      )

    assert out.assigns.last_dispatch_status =~ "error:",
           "an outsider with zero caps must be denied, got: #{inspect(out.assigns.last_dispatch_status)}"

    assert ConversationData.list_session_routing_rules(session_uri) == [],
           "LEAK: an unauthorized add_rule call must not persist a rule"
  end

  test "a malformed matcher form is rejected BEFORE any dispatch is attempted" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session_uri = new_session(owner)

    bad_params = %{
      "matcher_type" => "not_a_real_type",
      "matcher_arg" => "x",
      "receivers" => URI.to_string(owner)
    }

    {:noreply, out} =
      ConversationActions.handle_dispatch(
        socket_with_routing_cap(owner, session_uri, :add_rule),
        "session.routing.add",
        %{"session_uri" => URI.to_string(session_uri), "rule" => bad_params}
      )

    assert out.assigns.last_dispatch_status == "error:invalid_matcher_form"
    assert ConversationData.list_session_routing_rules(session_uri) == []
  end

  test "a bad rule id on toggle degrades to error:bad_rule_id (no crash, pure validation short-circuit)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session_uri = new_session(owner)

    {:noreply, out} =
      ConversationActions.handle_dispatch(
        socket_with_routing_cap(owner, session_uri, :enable_rule),
        "session.routing.toggle",
        %{"session_uri" => URI.to_string(session_uri), "id" => "not-a-number", "table" => "x"}
      )

    assert out.assigns.last_dispatch_status == "error:bad_rule_id"
  end
end

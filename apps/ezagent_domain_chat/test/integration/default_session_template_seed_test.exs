defmodule EzagentDomainChat.Integration.DefaultSessionTemplateSeedTest do
  @moduledoc """
  Task #50 (Allen 2026-05-27) — `seed_default_session_template/0` in
  `EzagentDomainChat.Application.start/2` populates a `default`
  SessionTemplate Kind under `workspace://system` at boot so
  `/admin/templates` is non-empty on a fresh install AND
  `mix ezagent workspace create_session --template-name default`
  resolves to a known team config without operator setup.

  The acceptance criterion (per task spec): "at boot in test env,
  assert `workspace://system` has a `default` session template
  visible." This test asserts:

  1. A SessionTemplate Kind whose URI's workspace segment is `system`
     and name segment is `default` is present in
     `Ezagent.Ecto.KindSnapshot.list_in_workspace("workspace://system")`.
  2. Its `:template` slice content carries the documented
     minimal-viable shape (empty `agent_slots`, empty `routing_rules`,
     `orchestrator_template_uri` pointing at the cc-orchestrator
     AgentTemplate seed URI).

  Boot runs in `test_helper.exs` (via `Application.ensure_all_started`);
  this test asserts the boot-time side effect. The seed is idempotent
  (content-addressable URI) so re-running the test suite doesn't
  duplicate rows.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Orchestrator.CcOrchestratorSeed

  @workspace_uri_str "workspace://system"

  test "workspace://system has a `default` session template at boot" do
    snapshots = KindSnapshot.list_in_workspace(@workspace_uri_str)

    default_template =
      Enum.find(snapshots, fn snap ->
        is_binary(snap.uri) and
          String.starts_with?(snap.uri, "template://session/system/default@")
      end)

    assert default_template != nil,
           "expected a `template://session/system/default@<hash>` SessionTemplate " <>
             "Kind seeded by `seed_default_session_template/0`; found " <>
             "#{inspect(Enum.map(snapshots, & &1.uri))}"
  end

  test "the seeded default template has the documented minimal-viable shape" do
    snapshots = KindSnapshot.list_in_workspace(@workspace_uri_str)

    default_template =
      Enum.find(snapshots, fn snap ->
        is_binary(snap.uri) and
          String.starts_with?(snap.uri, "template://session/system/default@")
      end)

    assert default_template != nil

    # `decode_state/1` prefers `state_binary` (term_to_binary roundtrip)
    # over the legacy JSON `state` map; both preserve the per-Behavior
    # slice keying (`:template`'s slice for SessionTemplate's
    # `Behavior.Template` registration).
    {:ok, state} = KindSnapshot.decode_state(default_template)
    template_slice = Map.get(state, :template) || Map.get(state, "template") || %{}
    content = Map.get(template_slice, :content) || Map.get(template_slice, "content") || %{}

    # The seed writes atom-keyed content. `state_binary` preserves
    # atom keys via term_to_binary roundtrip; the legacy JSON `state`
    # field would surface string keys — probe both shapes for
    # robustness across snapshot codec versions.
    name = Map.get(content, :name) || Map.get(content, "name")
    agent_slots = Map.get(content, :agent_slots) || Map.get(content, "agent_slots")
    routing_rules = Map.get(content, :routing_rules) || Map.get(content, "routing_rules")

    orchestrator_uri =
      Map.get(content, :orchestrator_template_uri) ||
        Map.get(content, "orchestrator_template_uri")

    assert name == "default"
    assert agent_slots == []
    assert routing_rules == []

    # orchestrator_template_uri may serialize as either a `%URI{}` or a
    # string depending on the snapshot codec — accept both shapes.
    orchestrator_uri_str =
      case orchestrator_uri do
        %URI{} = uri -> URI.to_string(uri)
        s when is_binary(s) -> s
        _ -> nil
      end

    assert orchestrator_uri_str == CcOrchestratorSeed.template_uri(),
           "expected orchestrator_template_uri to point at the cc-orchestrator " <>
             "AgentTemplate seed URI (`#{CcOrchestratorSeed.template_uri()}`); " <>
             "got #{inspect(orchestrator_uri)}"
  end
end

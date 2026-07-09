defmodule EzagentPluginHello.Integration.HelloFreezePinTest do
  @moduledoc """
  T-Pin-a2 (SPEC §4.4, §8.2 — codex round-2 BLOCKER): the freeze-pin helper is
  applied at the bespoke anon-homesite create path (`App.ensure_app/3`), NOT only
  in `SessionCreator`. That path is not retired in P0, so a hello install must be
  frozen to its create-time revision — a later publish must not silently change
  the running flagship.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}
  alias EzagentPluginHello.App

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    ws = "hello-pin-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Ezagent.Workspace.create(ws, %{})
    %{ws: ws}
  end

  # Read the persisted SessionTemplate content the session was created from,
  # unwrapping the Lifecycle two-container `:template` slice (state → content).
  defp persisted_template_content(session_uri) do
    wc = Session.read_template_working_copy(session_uri)
    tmpl = Map.get(wc, :session_template_uri) || Map.get(wc, "session_template_uri")

    {:ok, slice} = Ezagent.Kind.get_slice(tmpl, :template)
    persistent = Map.get(slice, :state) || Map.get(slice, "state") || slice
    Map.get(persistent, :content) || Map.get(persistent, "content") || %{}
  end

  defp installs_of(content),
    do: Map.get(content, :installs) || Map.get(content, "installs") || []

  defp pin_of(install),
    do: Map.get(install, :config_id) || Map.get(install, "config_id")

  test "ensure_app freezes the hello install into the persisted template content", %{ws: ws} do
    name = "main"
    {:ok, session_uri, _orch} = App.ensure_app(ws, name, defer_orchestrator: false)

    workspace = Ezagent.URI.workspace(ws)
    hello_def = "hello-#{name}"

    # the create-time (current) revision the freeze must pin to
    {:ok, _def_r1, r1} = DefinitionRegistry.lookup(workspace, hello_def)

    # the persisted template content carries a PINNED install (freeze ran here) —
    # a bare `installs: [ref]` would have no config_id.
    content = persisted_template_content(session_uri)
    # The template now carries hello + orchestrator installs (from `requires`);
    # the hello install must be among them with the freeze pin.
    installs = installs_of(content)
    hello_install = Enum.find(installs, &(is_binary(pin_of(&1)) and pin_of(&1) == r1.id))

    assert hello_install,
           "hello install with pinned config_id #{r1.id} not found in #{inspect(installs)}"

    # publish a NEW hello revision R2 with an extra behavior (SupervisorApproval).
    {:ok, r2_def} =
      Ezagent.Socialware.Definition.new(%{
        name: hello_def,
        bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
        shape: [
          Ezagent.ActionSet.Turn,
          Ezagent.ActionSet.Surface,
          Ezagent.ActionSet.SupervisorApproval
        ],
        adapters: [%{adapter_id: "external_feed", role: :customer, config: %{}}],
        visibility_policy: %{publish_policy: :auto, web_anon_access: true},
        # D-5 — anon def MUST declare a :fixed owner (matches the hello seed def).
        owner_policy: %{type: :installer}
      })

    {:ok, r2} =
      DefinitionRegistry.write_definition(r2_def,
        workspace_uri: workspace,
        caller_workspace_uri: workspace,
        actor_uri: Ezagent.Entity.User.admin_uri()
      )

    refute r2.id == r1.id

    # the FROZEN persisted content still resolves R1 (no SupervisorApproval),
    # while an UNFROZEN live lookup would now follow R2 — the freeze holds.
    {:ok, frozen_behaviors} = Installation.behavior_set_for_template(content, workspace)
    refute Ezagent.ActionSet.SupervisorApproval in frozen_behaviors

    {:ok, live_behaviors} =
      Installation.behavior_set_for_template(%{installs: [hello_def]}, workspace)

    assert Ezagent.ActionSet.SupervisorApproval in live_behaviors
  end
end

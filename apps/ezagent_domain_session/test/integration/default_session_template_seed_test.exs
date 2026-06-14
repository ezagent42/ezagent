defmodule EzagentDomainInstanceMessage.Integration.DefaultSessionTemplateSeedTest do
  @moduledoc """
  Task #50 (Allen 2026-05-27) — `seed_default_session_template/0` in
  `EzagentDomainInstanceMessage.Application.start/2` populates a `default`
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

  Boot runs in `test_helper.exs` (via `Application.ensure_all_started`)
  and writes the seeded row outside any per-test sandbox. To keep the
  test deterministic regardless of boot-time row state, `setup` calls
  the public test-only entry point
  `EzagentDomainInstanceMessage.Application.seed_default_session_template_now/0`
  inside the sandbox checkout — this exercises the same code path the
  boot uses (idempotent, content-addressable) and guarantees the
  assertion runs against a freshly-written snapshot. Codex review
  #419 round-1 HIGH-1.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.User

  @workspace_uri_str "workspace://system"

  # PR-8 (transport #53) — `Ezagent.Orchestrator.CcOrchestratorSeed` relocated
  # into the cc plugin (which this app does not depend on). The seed's
  # `template_uri/0` is the string form of
  # `Ezagent.URI.template(:system, :agent, "cc-orchestrator")`; inline it so
  # this im test never names the cc-resident module. Behavior-identical.
  defp cc_orchestrator_template_uri_str,
    do: :system |> Ezagent.URI.template(:agent, "cc-orchestrator") |> URI.to_string()

  setup do
    # Drive the seed deterministically inside the sandbox checkout so
    # the assertion doesn't depend on whether the boot-time write
    # landed before the test owner took over the connection. Idempotent
    # (content-addressable) — no-op when the row already exists.
    :ok = EzagentDomainInstanceMessage.Application.seed_default_session_template_now()
    :ok
  end

  test "seed_default_session_template_now/1 seeds `default` in the requested workspace" do
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert :ok = EzagentDomainInstanceMessage.Application.seed_default_session_template_now(workspace_uri)

    snapshots = KindSnapshot.list_in_workspace("workspace://team-alpha")

    assert Enum.any?(snapshots, fn snap ->
             is_binary(snap.uri) and
               String.starts_with?(snap.uri, "template://team-alpha/session/default@")
           end),
           "expected a per-workspace `template://team-alpha/session/default@<hash>` " <>
             "SessionTemplate seed; found #{inspect(Enum.map(snapshots, & &1.uri))}"
  end

  test "create_session/3 ensures a per-workspace default template before resolving it" do
    workspace_name = "seed-ws-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")
    short = "from-default-#{System.unique_integer([:positive])}"

    {:ok, _pid} = Ezagent.Workspace.create(workspace_name, %{})

    assert {:ok, session_uri, _meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               workspace_uri: workspace_uri,
               template_name: "default"
             )

    assert URI.to_string(session_uri) == "session://#{workspace_name}/default/#{short}"

    assert workspace_name
           |> default_template_uri_prefix()
           |> snapshot_exists?()
  end

  test "workspace://system has a `default` session template at boot" do
    snapshots = KindSnapshot.list_in_workspace(@workspace_uri_str)

    default_template =
      Enum.find(snapshots, fn snap ->
        is_binary(snap.uri) and
          String.starts_with?(snap.uri, "template://system/session/default@")
      end)

    assert default_template != nil,
           "expected a `template://system/session/default@<hash>` SessionTemplate " <>
             "Kind seeded by `seed_default_session_template/0`; found " <>
             "#{inspect(Enum.map(snapshots, & &1.uri))}"
  end

  test "the seeded default template has the documented minimal-viable shape" do
    snapshots = KindSnapshot.list_in_workspace(@workspace_uri_str)

    default_template =
      Enum.find(snapshots, fn snap ->
        is_binary(snap.uri) and
          String.starts_with?(snap.uri, "template://system/session/default@")
      end)

    assert default_template != nil

    # `decode_state/1` prefers `state_binary` (term_to_binary roundtrip)
    # over the legacy JSON `state` map; both preserve the per-Behavior
    # slice keying (`:template`'s slice for SessionTemplate's
    # `Behavior.Template` registration).
    {:ok, state} = KindSnapshot.decode_state(default_template)
    template_slice = Map.get(state, :template) || Map.get(state, "template") || %{}

    # Lifecycle migration (SPEC 2026-05-29): `Ezagent.Behavior.Template`
    # now `use Ezagent.Lifecycle`, so the PERSISTED `:template` slice is
    # the two-container `%{state: %{content: ...}}` shape (the framework
    # persists only `:state`; `:transients` is stripped at the serialize
    # boundary). Unwrap to the persistent `:state` view before reading
    # `:content` — a pre-migration flat slice falls through unchanged.
    template_persistent =
      Map.get(template_slice, :state) || Map.get(template_slice, "state") || template_slice

    content =
      Map.get(template_persistent, :content) || Map.get(template_persistent, "content") || %{}

    # The seed writes atom-keyed content. `state_binary` preserves
    # atom keys via term_to_binary roundtrip; the legacy JSON `state`
    # field would surface string keys — probe both shapes for
    # robustness across snapshot codec versions.
    name = Map.get(content, :name) || Map.get(content, "name")
    routing_rules = Map.get(content, :routing_rules) || Map.get(content, "routing_rules")

    # team-routing-unification §3.7 (PR-7) — `agent_slots` is no longer a
    # SessionTemplate content field (PR-8 removes the slot tools). The
    # orchestrator-only default template now carries the PR-7 content shape:
    # empty `members` / `prompt_templates` / `legends`.
    members = Map.get(content, :members) || Map.get(content, "members")
    prompt_templates = Map.get(content, :prompt_templates) || Map.get(content, "prompt_templates")
    legends = Map.get(content, :legends) || Map.get(content, "legends")

    orchestrator_uri =
      Map.get(content, :orchestrator_template_uri) ||
        Map.get(content, "orchestrator_template_uri")

    assert name == "default"

    refute Map.has_key?(content, :agent_slots) or Map.has_key?(content, "agent_slots"),
           "PR-7: `agent_slots` must NOT be a SessionTemplate content field; got #{inspect(content)}"

    assert members == []
    assert prompt_templates == %{}
    assert legends == %{}
    assert routing_rules == []

    # orchestrator_template_uri may serialize as either a `%URI{}` or a
    # string depending on the snapshot codec — accept both shapes.
    orchestrator_uri_str =
      case orchestrator_uri do
        %URI{} = uri -> URI.to_string(uri)
        s when is_binary(s) -> s
        _ -> nil
      end

    assert orchestrator_uri_str == cc_orchestrator_template_uri_str(),
           "expected orchestrator_template_uri to point at the cc-orchestrator " <>
             "AgentTemplate seed URI (`#{cc_orchestrator_template_uri_str()}`); " <>
             "got #{inspect(orchestrator_uri)}"
  end

  # 2026-05-31 orchestrator-startup-atomicity §3 — the seed is a HARD boot
  # invariant in prod/dev (crash boot if it can't persist) but `:test` is
  # CARVED OUT (best-effort; Ecto SQL Sandbox). This test asserts the
  # carve-out: the test-only entry returns `:ok` (NOT a crash) and the
  # boot we are running inside did NOT abort — if the §3 carve-out were
  # wrong (hard-crashing in test), the whole suite's boot would fail and
  # this test could never run.
  test "§3 seed-invariant test-env carve-out: seed is best-effort in :test" do
    # Idempotent re-run inside the sandbox — must be `:ok`, never a raise
    # (the prod/dev path raises on `{:error, _}`; the test path tolerates).
    assert :ok = EzagentDomainInstanceMessage.Application.seed_default_session_template_now()

    # The carve-out only applies in :test — guard that we ARE in test env
    # (otherwise this assertion is meaningless).
    assert Mix.env() == :test
  end

  defp default_template_uri_prefix(workspace_name),
    do: "template://#{workspace_name}/session/default@"

  defp snapshot_exists?(prefix) do
    KindSnapshot.list_all()
    |> Enum.any?(fn snap -> is_binary(snap.uri) and String.starts_with?(snap.uri, prefix) end)
  end
end

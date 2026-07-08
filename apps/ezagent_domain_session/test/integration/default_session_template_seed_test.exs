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
     minimal-viable shape: no `agent_slots`, empty `members`, empty
     `routing_rules`, and installs the `chat` + `orchestrator` socialware.

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

  setup do
    # Drive the seed deterministically inside the sandbox checkout so
    # the assertion doesn't depend on whether the boot-time write
    # landed before the test owner took over the connection. Idempotent
    # (content-addressable) — no-op when the row already exists.
    :ok = EzagentDomainInstanceMessage.Application.seed_default_session_template_now()
    :ok = seed_orchestrator_recipe()
    :ok
  end

  test "seed_default_session_template_now/1 seeds `default` in the requested workspace" do
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert :ok =
             EzagentDomainInstanceMessage.Application.seed_default_session_template_now(
               workspace_uri
             )

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

    # Lifecycle migration (SPEC 2026-05-29): `Ezagent.ActionSet.Template`
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
    # M2 — the default template installs the orchestrator Definition. It no
    # longer carries a legacy hardcoded cc-orchestrator member declaration.
    members = Map.get(content, :members) || Map.get(content, "members")
    prompt_templates = Map.get(content, :prompt_templates) || Map.get(content, "prompt_templates")
    legends = Map.get(content, :legends) || Map.get(content, "legends")
    installs = Map.get(content, :installs) || Map.get(content, "installs")

    assert name == "default"

    refute Map.has_key?(content, :agent_slots) or Map.has_key?(content, "agent_slots"),
           "PR-7: `agent_slots` must NOT be a SessionTemplate content field; got #{inspect(content)}"

    assert members == []
    assert prompt_templates == %{}
    assert legends == %{}
    assert routing_rules == []
    assert installs == ["chat", "orchestrator"]

    refute Map.has_key?(content, :orchestrator_template_uri)
    refute Map.has_key?(content, "orchestrator_template_uri")
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

  # ── Task #58 — default SessionTemplate ⇄ cc decoupling ──────────────
  #
  # The orchestrator AgentTemplate URI the default template is seeded with
  # is now a deployment seam read from
  # `:ezagent_domain_session, :default_orchestrator_template_uri`. The
  # tests above prove the cc-INCLUSIVE side (key set in config/config.exs →
  # the default is orchestrator-bearing, pointing at cc-orchestrator). The
  # tests below force the cc-LESS (`im-without-cc`) side: blank the key so
  # the default seeds PLAIN, and assert `create_session("default")`
  # succeeds as a plain session — the edge that previously broke with
  # `{:orchestrator_ensure_failed, {:unknown_flavor, "cc"}}` when the cc
  # plugin (and so the `"cc"` flavor + cc-orchestrator AgentTemplate) is
  # absent.
  #
  # We force the condition explicitly (set config → nil) rather than rely
  # on ambient state: the monorepo test build always loads cc, so a test
  # depending on ambient composition would pass trivially and prove
  # nothing.
  describe "Task #58 — cc-less (im-without-cc) deployment" do
    setup do
      prior = Application.get_env(:ezagent_domain_session, :default_orchestrator_template_uri)
      # cc-LESS deployment omits the seam → nil.
      Application.delete_env(:ezagent_domain_session, :default_orchestrator_template_uri)

      on_exit(fn ->
        case prior do
          nil ->
            Application.delete_env(:ezagent_domain_session, :default_orchestrator_template_uri)

          _ ->
            Application.put_env(
              :ezagent_domain_session,
              :default_orchestrator_template_uri,
              prior
            )
        end
      end)

      :ok
    end

    test "the default template still installs orchestrator when the legacy cc seam is unset" do
      workspace_name = "ccless-ws-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")

      assert :ok =
               EzagentDomainInstanceMessage.Application.seed_default_session_template_now(
                 workspace_uri
               )

      snapshot =
        KindSnapshot.list_in_workspace(URI.to_string(workspace_uri))
        |> Enum.find(fn snap ->
          is_binary(snap.uri) and
            String.starts_with?(snap.uri, default_template_uri_prefix(workspace_name))
        end)

      assert snapshot != nil, "expected a default template seeded for #{workspace_name}"

      {:ok, state} = KindSnapshot.decode_state(snapshot)
      template_slice = Map.get(state, :template) || Map.get(state, "template") || %{}

      template_persistent =
        Map.get(template_slice, :state) || Map.get(template_slice, "state") || template_slice

      content =
        Map.get(template_persistent, :content) || Map.get(template_persistent, "content") || %{}

      members = Map.get(content, :members) || Map.get(content, "members")

      installs = Map.get(content, :installs) || Map.get(content, "installs")

      assert members == []
      assert installs == ["chat", "orchestrator"]

      refute Map.has_key?(content, :orchestrator_template_uri)
      refute Map.has_key?(content, "orchestrator_template_uri")
    end

    test "create_session(default) resolves the orchestrator install even when the legacy seam is unset" do
      workspace_name = "ccless-create-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")
      short = "from-default-#{System.unique_integer([:positive])}"

      {:ok, _pid} = Ezagent.Workspace.create(workspace_name, %{})

      assert {:ok, session_uri, meta} =
               EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
                 workspace_uri: workspace_uri,
                 template_name: "default"
               )

      assert URI.to_string(session_uri) == "session://#{workspace_name}/default/#{short}"

      # The legacy direct template URI seam is gone; the stock orchestrator is
      # selected by Definition role recipe+flavor instead.
      assert meta == %{}
    end
  end

  # ── fix/template-name-resolution — Prong 2: the seed tags the version ──
  #
  # `do_seed_default_session_template` must write/repoint the
  # `default`→`current` TemplateTag at the version it just persisted, so
  # `TemplateResolver.find_session_template_uri` resolves via the
  # deterministic tag path and the scan is only a true fallback.
  describe "fix/template-name-resolution — seed writes the `default`→`current` tag" do
    alias Ezagent.TemplateTags

    test "after the default seed runs, `default`→`current` resolves to the seeded version" do
      workspace_name = "tag-seed-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")

      assert :ok =
               EzagentDomainInstanceMessage.Application.seed_default_session_template_now(
                 workspace_uri
               )

      seeded_hash = seeded_default_hash(workspace_name)
      assert is_binary(seeded_hash) and seeded_hash != ""

      assert {:ok, ^seeded_hash} = TemplateTags.resolve(workspace_uri, "default", "current"),
             "expected the `default`→`current` tag to point at the seeded version #{seeded_hash}"
    end

    test "re-seeding repoints the tag from a stale hash back to the current version" do
      workspace_name = "tag-repoint-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")

      assert :ok =
               EzagentDomainInstanceMessage.Application.seed_default_session_template_now(
                 workspace_uri
               )

      current_hash = seeded_default_hash(workspace_name)

      # Simulate a prior version's tag lingering on a stale hash.
      stale_hash = :crypto.hash(:sha256, "stale-#{workspace_name}") |> Base.encode16(case: :lower)
      refute stale_hash == current_hash
      :ok = TemplateTags.put(workspace_uri, "default", "current", stale_hash, nil)
      assert {:ok, ^stale_hash} = TemplateTags.resolve(workspace_uri, "default", "current")

      # Re-running the seed (idempotent, content-addressed) must repoint the
      # tag back at the current version — upgrade-aware, not append-only.
      assert :ok =
               EzagentDomainInstanceMessage.Application.seed_default_session_template_now(
                 workspace_uri
               )

      assert {:ok, ^current_hash} = TemplateTags.resolve(workspace_uri, "default", "current")
    end
  end

  # Read the seeded `default` version's `@<hash>` from its snapshot URI.
  defp seeded_default_hash(workspace_name) do
    prefix = default_template_uri_prefix(workspace_name)

    KindSnapshot.list_in_workspace("workspace://#{workspace_name}")
    |> Enum.find_value(fn snap ->
      if is_binary(snap.uri) and String.starts_with?(snap.uri, prefix) do
        String.replace_prefix(snap.uri, prefix, "")
      end
    end)
  end

  defp default_template_uri_prefix(workspace_name),
    do: "template://#{workspace_name}/session/default@"

  defp snapshot_exists?(prefix) do
    KindSnapshot.list_all()
    |> Enum.any?(fn snap -> is_binary(snap.uri) and String.starts_with?(snap.uri, prefix) end)
  end

  defp seed_orchestrator_recipe do
    recipe =
      [Ezagent, Orchestrator, OrchestratorRecipe]
      |> Module.concat()
      |> apply(:recipe, [])

    case Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

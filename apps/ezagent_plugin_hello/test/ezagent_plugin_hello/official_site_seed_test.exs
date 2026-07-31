defmodule EzagentPluginHello.OfficialSiteSeedTest do
  @moduledoc """
  The governed 官网 deploy-seed invariant: `OfficialSiteSeed.ensure/0`
  provisions `session://ezagent/hello/ezagent-official` (the ruihua marketing
  page + greeter) in the hello HOME workspace when it is ABSENT — the self-heal
  a reseed depends on — and SKIPS the re-drive when the site already has a
  page, so a plain reboot never clobbers a live `refresh_hello_site.exs`
  refresh.

  hello-A: the 官网 is an ezagent-MEMBER session (owner = the home workspace's
  founder, falling back to `entity://ezagent/user/lin_yilun`), never the
  `system`-pinned singleton it replaced.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.{Profile, User}
  alias Ezagent.Socialware.ExternalFeed
  alias EzagentPluginHello.OfficialSiteSeed

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kanban)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    # Stale-Kind hygiene: sibling tests in this BEAM (the credential-source +
    # workspace-isolation integration tests) create the SAME home-workspace /
    # lin_yilun / 官网-session names; their DB rows roll back with the sandbox
    # but the live Kind processes (and the signed caps/keys in their state)
    # survive, surfacing as `:invalid_cap_signature` here. Terminate them so
    # every create below is a FRESH spawn consistent with this transaction.
    home = EzagentPluginHello.home_workspace()

    Enum.each(
      [
        Ezagent.URI.session(home, :hello, "ezagent-official"),
        Ezagent.URI.entity(home, :user, "lin_yilun"),
        Ezagent.URI.workspace(home)
      ],
      &terminate/1
    )

    # Routing-registry hygiene: the seed's INTERIM delivery-rule wiring writes
    # the live RoutingRegistry ETS, which survives the DataCase transaction's
    # DB rollback. Reconcile ETS from the (clean) DB so no stale rule from a
    # sibling test leaks into this one.
    :ok =
      Ezagent.Routing.Resolver.default_routing_table()
      |> Ezagent.Routing.RuleStore.load_into_registry()

    # Isolate this test to the SITE-provisioning invariant. `ensure/0` also
    # wires the llm responder's DeepSeek credential (`:put_api_key` from
    # `DEEPSEEK_API_KEY`); with no key that leg skips with a warning and the
    # `llm` member keyless-spawns — the page still provisions, which is all
    # this invariant asserts. The credential + delivery-rule wiring has its
    # own test below (it sets the env var explicitly).
    prev_key = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      if prev_key, do: System.put_env("DEEPSEEK_API_KEY", prev_key)
    end)

    # The 官网 owner (the lin_yilun fallback on this founder-less test stack)
    # must be a REAL user — the member-cap grant flow absorbs caps into the
    # owner entity at materialize time (`identity.absorb_cap`), which fails
    # `:no_such_actor` for a URI with no users row. On deploys lin_yilun is a
    # real ezagent-workspace user; create the row here the same way.
    owner = Ezagent.URI.entity(EzagentPluginHello.home_workspace(), :user, "lin_yilun")
    {:ok, _} = Ezagent.Users.create(owner, nil, [], email_verified: false)
    email = "official-founder@example.test"

    {:ok, _} =
      Profile.upsert(%{entity_uri: owner, display_name: "Official founder", email: email})

    previous = Application.get_env(:ezagent_plugin_hello, :official_site_founder_email)
    Application.put_env(:ezagent_plugin_hello, :official_site_founder_email, email)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ezagent_plugin_hello, :official_site_founder_email, previous),
        else: Application.delete_env(:ezagent_plugin_hello, :official_site_founder_email)
    end)

    :ok
  end

  test "the site URI tracks the single home-workspace source (split-brain invariant leg)" do
    site_uri = OfficialSiteSeed.site_uri()
    home = EzagentPluginHello.home_workspace()

    assert site_uri == Ezagent.URI.session(home, :hello, "ezagent-official")
    assert Ezagent.Capability.workspace_of(site_uri) == Ezagent.URI.workspace(home)
  end

  test "provisions ezagent/hello/ezagent-official from absence, then skips when already present" do
    site_uri = OfficialSiteSeed.site_uri()
    assert site_uri == Ezagent.URI.session("ezagent", :hello, "ezagent-official")

    # Precondition — the 官网 is absent (nothing else provisions it).
    refute site_page_present?(site_uri)

    # Self-heal: absent → provision the greeter session + drive the ruihua page.
    assert {:ok, {:provisioned, ^site_uri, turn_id}} = OfficialSiteSeed.ensure()
    assert is_binary(turn_id) and turn_id != ""

    # hello-A — the session owner is an ezagent principal (the home workspace's
    # founder, or the lin_yilun fallback on this founder-less test stack),
    # NEVER the system admin.
    assert {:ok, owner_uri} = Ezagent.Entity.Session.owner(site_uri)
    assert Ezagent.Capability.workspace_of(owner_uri) == Ezagent.URI.workspace("ezagent")
    refute URI.to_string(owner_uri) == URI.to_string(User.admin_uri())

    # The committed ruihua marketing page ("组织的 IDE") is on the Surface.
    expected_body = seed_path("body.json") |> File.read!() |> Jason.decode!()
    expected_css = seed_path("shell.css") |> File.read!()

    assert {:ok, snapshot} = ExternalFeed.snapshot(site_uri, User.admin_uri())
    assert snapshot.page == expected_body
    assert snapshot.shell_css == expected_css

    # Absence gate: a second run finds the page present and SKIPS the re-drive
    # (a plain reboot preserves a live GitHub-data refresh).
    assert {:ok, {:already_provisioned, ^site_uri}} = OfficialSiteSeed.ensure()

    # And the page is unchanged after the skipped run.
    assert {:ok, snapshot2} = ExternalFeed.snapshot(site_uri, User.admin_uri())
    assert snapshot2.page == expected_body
  end

  # INTERIM workaround wiring (removed by the #1667 structural fix): the seed
  # must durably re-create what live-prod patched by hand — (a) the llm
  # greeter's DeepSeek credential (from `DEEPSEEK_API_KEY`, COMPARE-AND-SET so
  # a rerun NEVER overwrites) and (b) EXACTLY ONE seed-owned session-scoped
  # MentionRouting delivery rule that really routes in-session messages.
  test "wires the llm credential + one seed-owned delivery rule; rerun never overwrites" do
    key = "sk-official-site-seed-test-key"
    System.put_env("DEEPSEEK_API_KEY", key)
    on_exit(fn -> System.delete_env("DEEPSEEK_API_KEY") end)

    site_uri = OfficialSiteSeed.site_uri()
    table = Ezagent.Routing.Resolver.default_routing_table()

    assert {:ok, {:provisioned, ^site_uri, _turn_id}} = OfficialSiteSeed.ensure()
    assert {:ok, llm_uri} = EzagentPluginHello.Members.role_uri(site_uri, "llm")
    assert {:ok, owner_uri} = Ezagent.Entity.Session.owner(site_uri)

    # VM-global hygiene: the llm Kind process and the RoutingRegistry ETS
    # entry survive the sandbox rollback — remove both so sibling tests see
    # neither a stale credential nor a dead-agent delivery rule.
    on_exit(fn ->
      terminate(llm_uri)

      table
      |> owned_delivery_rules(site_uri)
      |> Enum.each(&Ezagent.Routing.RuleStore.delete(&1.id, force: true))

      :ok = Ezagent.Routing.RuleStore.load_into_registry(table)
    end)

    # (a) The DeepSeek credential landed on the llm greeter agent.
    assert {:ok, slice} = Ezagent.Kind.read(llm_uri, :api_keys)
    assert get_in(slice, [:keys, "deepseek"]) == key

    # (b) EXACTLY ONE seed-owned row: marked, enabled, admin-sourced, and
    # pointing at EXACTLY the current llm member (membership is not enough).
    assert [row] = owned_delivery_rules(table, site_uri)
    assert row.rule_set == "official-site-interim"
    assert row.enabled
    assert row.source == "admin"
    assert row.receivers == [URI.to_string(llm_uri)]

    # (c) REAL delivery: the hydrated registry routes an in-session message
    # to the llm agent.
    message = %Ezagent.Message{
      id: "msg-seed-test-#{System.unique_integer([:positive])}",
      session_uri: site_uri,
      sender: owner_uri,
      mentions: [],
      body: %{text: "你好官网", attachments: []},
      inserted_at: DateTime.utc_now()
    }

    assert llm_uri in Ezagent.Routing.Resolver.resolve(message, site_uri, [])

    # Watch the llm's api_keys slice across the rerun: a second `:api_key_put`
    # would commit a `:set` effect → `{:slice_changed, _}` broadcast.
    :ok = Ezagent.SliceChange.subscribe_unverified(llm_uri)

    # Idempotent rerun with a DIFFERENT env key (the operator-rotated-env
    # shape): the already-provisioned path must NOT overwrite the ORIGINAL
    # key, must NOT emit a second :api_key_put, and must NOT touch the rule.
    System.put_env("DEEPSEEK_API_KEY", "sk-rotated-env-key-must-not-land")
    assert {:ok, {:already_provisioned, ^site_uri}} = OfficialSiteSeed.ensure()

    assert {:ok, slice2} = Ezagent.Kind.read(llm_uri, :api_keys)
    assert get_in(slice2, [:keys, "deepseek"]) == key
    refute_received {:slice_changed, _}, 250

    assert [row2] = owned_delivery_rules(table, site_uri)
    assert row2.id == row.id
  end

  # codex must-fix #1 (tri-state): when the llm agent's :api_keys slice is
  # UNREADABLE (here: never-durably-created after teardown — the same
  # `{:error, _}` bucket as a ReadyGate `{:not_ready, _}`), the credential
  # leg must SKIP with a warning — never blindly put over what it cannot
  # see — while the independent routing leg still reconciles and the seed
  # outcome stays healthy.
  test "unreadable llm api_keys slice: credential leg skips (no put, no respawn)" do
    key = "sk-unreadable-slice-test-key"
    System.put_env("DEEPSEEK_API_KEY", key)
    on_exit(fn -> System.delete_env("DEEPSEEK_API_KEY") end)

    site_uri = OfficialSiteSeed.site_uri()
    table = Ezagent.Routing.Resolver.default_routing_table()

    assert {:ok, {:provisioned, ^site_uri, _turn_id}} = OfficialSiteSeed.ensure()
    assert {:ok, llm_uri} = EzagentPluginHello.Members.role_uri(site_uri, "llm")

    on_exit(fn ->
      terminate(llm_uri)

      table
      |> owned_delivery_rules(site_uri)
      |> Enum.each(&Ezagent.Routing.RuleStore.delete(&1.id, force: true))

      :ok = Ezagent.Routing.RuleStore.load_into_registry(table)
    end)

    assert {:ok, slice} = Ezagent.Kind.read(llm_uri, :api_keys)
    assert get_in(slice, [:keys, "deepseek"]) == key

    # Make the slice UNREADABLE: stop the live Kind AND remove its durable
    # snapshot, so `Kind.read/3` refuses the cold respawn (`:not_created`).
    terminate(llm_uri)

    EzagentCore.Repo.delete_all(
      from(k in Ezagent.Ecto.KindSnapshot, where: k.uri == ^URI.to_string(llm_uri))
    )

    :ok = Ezagent.SliceChange.subscribe_unverified(llm_uri)

    # The seed still succeeds end-to-end (wiring failures never fail it).
    assert {:ok, {:already_provisioned, ^site_uri}} = OfficialSiteSeed.ensure()

    # No put was dispatched (no slice event) and the seed did NOT respawn the
    # agent to force the key in.
    refute_received {:slice_changed, _}, 250
    assert :error = Ezagent.KindRegistry.lookup(llm_uri)

    # The routing leg is independent — the delivery rule is still exactly one.
    assert [_] = owned_delivery_rules(table, site_uri)
  end

  # codex must-fix #2 (duplicate guard): N concurrent reseeds (the two
  # deploy-node shape) that ALL observe the delivery rule absent must
  # converge to EXACTLY ONE seed-owned row — enforced at the DB level by the
  # `routing_rules_official_site_interim_unique` partial unique index (the
  # racing loser's insert violates it and adopts the winner's row).
  test "concurrent reseeds converge to exactly one delivery rule (duplicate guard)" do
    key = "sk-concurrent-guard-test-key"
    System.put_env("DEEPSEEK_API_KEY", key)
    on_exit(fn -> System.delete_env("DEEPSEEK_API_KEY") end)

    site_uri = OfficialSiteSeed.site_uri()
    table = Ezagent.Routing.Resolver.default_routing_table()

    assert {:ok, {:provisioned, ^site_uri, _turn_id}} = OfficialSiteSeed.ensure()
    assert {:ok, llm_uri} = EzagentPluginHello.Members.role_uri(site_uri, "llm")

    on_exit(fn ->
      terminate(llm_uri)

      table
      |> owned_delivery_rules(site_uri)
      |> Enum.each(&Ezagent.Routing.RuleStore.delete(&1.id, force: true))

      :ok = Ezagent.Routing.RuleStore.load_into_registry(table)
    end)

    # Remove the seeded row so EVERY racer observes absence.
    table
    |> owned_delivery_rules(site_uri)
    |> Enum.each(&Ezagent.Routing.RuleStore.delete(&1.id, force: true))

    :ok = Ezagent.Routing.RuleStore.load_into_registry(table)
    assert [] = owned_delivery_rules(table, site_uri)

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> OfficialSiteSeed.ensure() end) end)
      |> Enum.map(&Task.await(&1, 60_000))

    assert Enum.all?(results, &match?({:ok, {:already_provisioned, ^site_uri}}, &1))

    assert [row] = owned_delivery_rules(table, site_uri)
    assert row.rule_set == "official-site-interim"
    assert row.enabled
    assert row.receivers == [URI.to_string(llm_uri)]
  end

  # Mirrors `OfficialSiteSeed`'s seed-owned predicate: marker rows plus
  # legacy pre-marker rows from this same workaround (admin-attributed
  # in_session rules for THIS session without a rule_set).
  defp owned_delivery_rules(table, site_uri) do
    matcher_json =
      site_uri |> Ezagent.Routing.Matcher.in_session() |> Ezagent.Routing.Matcher.to_json()

    admin = URI.to_string(User.admin_uri())

    table
    |> Ezagent.Routing.RuleStore.list()
    |> Enum.filter(fn rule ->
      rule.rule_set == "official-site-interim" or
        (is_nil(rule.rule_set) and rule.matcher_data == matcher_json and
           rule.created_by == admin)
    end)
  end

  # #207: `resolve_founder` validates the configured email → Profile → workspace
  # but a Profile row is decoupled from the `users` provisioning row (separate
  # tables, no FK). A founder that has a Profile+email but NO `users` row would
  # pass the pre-guard `resolve_founder` and be handed to `provision/1`, where
  # the owner member-cap `identity.absorb_cap` casts to a URI whose user Kind
  # cannot cold-start → `:no_such_actor` and the ~60s absorb retry loop observed
  # on canary. The fix is a fail-loud startability check: reject an
  # unregistered founder at resolution, so the deploy provisions the user
  # (Allen's "add the user, don't soften") instead of silently retry-looping.
  test "fails loud when the configured founder has a profile but no registered user" do
    home = EzagentPluginHello.home_workspace()
    # A founder with a Profile (so `by_email` resolves it) but NO `users` row.
    founder = Ezagent.URI.entity(home, :user, "unregistered_founder")
    email = "unregistered-founder@example.test"

    {:ok, _} =
      Profile.upsert(%{entity_uri: founder, display_name: "Unregistered founder", email: email})

    Application.put_env(:ezagent_plugin_hello, :official_site_founder_email, email)

    assert {:error, :official_site_founder_not_registered} = OfficialSiteSeed.ensure()

    # Fail-loud is EARLY — the site is never even attempted, so no owner-cap
    # absorb is cast to the dead actor.
    refute site_page_present?(OfficialSiteSeed.site_uri())
  end

  test "fails loud when the configured founder is soft-disabled" do
    home = EzagentPluginHello.home_workspace()
    founder = Ezagent.URI.entity(home, :user, "disabled_founder")
    email = "disabled-founder@example.test"

    {:ok, _} = Ezagent.Users.create(founder, nil, [], email_verified: false)

    {:ok, _} =
      Profile.upsert(%{entity_uri: founder, display_name: "Disabled founder", email: email})

    {:ok, _} = Ezagent.Users.disable(founder, User.admin_uri(), "test")

    Application.put_env(:ezagent_plugin_hello, :official_site_founder_email, email)

    assert {:error, :official_site_founder_not_registered} = OfficialSiteSeed.ensure()
  end

  # #224 Fix 2 — at seed the owner was granted ONLY the tier-1 membership cap
  # (`cap(:session, Session, :receive, S)`) by `MemberCap.grant_owner_at_creation`;
  # the participation tier (`:send`/`:leave`/`:attach`) is minted by
  # `Membership.mount_participation_caps/2`, which never ran on the create path.
  # So the official-site owner could `:receive` but their FIRST `session.send`
  # (via `/socialware/external`) failed `:missing_cap`. `App.create_app/3` now
  # mounts the participation tier at creation. This pins the observable outcome:
  # the seeded owner HOLDS `:send` after `ensure/0`. (Red on today's receive-only
  # grant, green with the fix.)
  test "the official-site owner holds :send after seed (first session.send is authorized)" do
    site_uri = OfficialSiteSeed.site_uri()

    assert {:ok, {:provisioned, ^site_uri, _turn_id}} = OfficialSiteSeed.ensure()
    assert {:ok, owner_uri} = Ezagent.Entity.Session.owner(site_uri)

    assert wait_owner_send_cap(owner_uri, site_uri),
           "the official-site owner must hold cap(:session, Session, :send, S) after seed — " <>
             "without the participation-tier mount the owner's first session.send fails " <>
             ":missing_cap (#224 Fix 2)"
  end

  defp owner_holds_send_cap?(%URI{} = owner_uri, %URI{} = session_uri) do
    Enum.any?(Ezagent.Identity.list_caps_for(owner_uri), fn cap ->
      match?(%Capability{}, cap) and
        cap.kind == :session and
        cap.behavior == Ezagent.ActionSet.Session and
        Capability.action_of(cap) == :send and
        cap.instance == session_uri
    end)
  end

  defp wait_owner_send_cap(owner_uri, session_uri, retries \\ 50) do
    cond do
      owner_holds_send_cap?(owner_uri, session_uri) -> true
      retries > 0 -> Process.sleep(20) && wait_owner_send_cap(owner_uri, session_uri, retries - 1)
      true -> false
    end
  end

  # Mirrors `OfficialSiteSeed`'s internal absence gate.
  defp site_page_present?(site_uri) do
    match?(
      {:ok, %{page: page}} when not is_nil(page),
      ExternalFeed.snapshot(site_uri, User.admin_uri())
    )
  end

  defp seed_path(file) do
    :ezagent_plugin_hello
    |> :code.priv_dir()
    |> Path.join("seed_page")
    |> Path.join(file)
  end

  defp terminate(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      _ -> :ok
    end
  end
end

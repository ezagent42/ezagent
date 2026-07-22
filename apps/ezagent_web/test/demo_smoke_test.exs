defmodule EzagentCore.Invariants.DemoSmokeTest do
  @moduledoc """
  Phase 6 PR 12b → 12c — invariant tests that would have caught the
  three bugs surfaced by the live demo recording.

  Each test pins the actual surface the demo touched, not just an
  internal contract. Lesson per memory
  `feedback_completion_requires_invariant_test`: unit tests that pass
  on internal shape do NOT prove the user-facing flow works.

  ## Bug 1 — Repo `database:` missing from plain mix tasks

  PR 1 moved Repo `database:` to runtime.exs only. `mix phx.server`
  worked, but plain mix tasks (ezagent.user.set_password etc.) fail
  because mix tasks do not always evaluate runtime.exs before
  Application.ensure_all_started. The hotfix puts a default back in
  dev.exs; runtime.exs still overrides for releases + phx.server.

  Test: assert `Application.get_env(:ezagent_core, EzagentCore.Repo)[:database]`
  is set + points inside `Ezagent.Home.path(:db)`.

  ## Bug 2 — Tailwind didn't scan plugin LV sources

  Shadcn-style classes in ezagent_domain_ui weren't
  in the compiled CSS bundle because the @source list only covered
  ezagent_web/lib. Pages rendered unstyled.

  Test: grep priv/static/assets/css/app.css for a class that ONLY
  appears in the new components (e.g. `bg-zinc-900` from
  EzagentDomainUi.Components button primary variant).

  ## Bug 3 — AutoDerive list_instances was empty

  Read wrong state field names (`:kind_module` vs actual `:kind`,
  `:slices` vs actual `:state`) and didn't parse the string URI
  stored in KindRegistry. Result: empty list for every known Kind.

  Test: AutoDerive.list_instances(:user) must contain entity://user/admin.
  """
  use EzagentCore.DataCase, async: false

  # Sandbox provided by EzagentCore.DataCase (#92).

  defp create_session_via_workspace(short_name, creator_uri, opts) do
    template_name = Keyword.fetch!(opts, :template_name)

    workspace_uri =
      Keyword.get(opts, :workspace_uri, Ezagent.Capability.workspace_of(creator_uri))

    ensure_workspace_seeded!(workspace_uri)

    with {:ok, result} <-
           Ezagent.Workspace.create_session(
             workspace_uri,
             %{short_name: short_name, template_name: template_name},
             %{
               caller: creator_uri,
               authenticated_principal: creator_uri,
               caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
             }
           ) do
      {:ok, result.session_uri, %{}}
    end
  end

  defp ensure_workspace_seeded!(workspace_uri, retries \\ 5)

  defp ensure_workspace_seeded!(%URI{scheme: "workspace", host: name} = workspace_uri, retries)
       when is_binary(name) and name != "" do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        try do
          case Ezagent.Workspace.create(name, %{}) do
            {:ok, _pid} -> :ok
            {:error, :workspace_exists} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, reason} -> raise "failed to seed workspace #{name}: #{inspect(reason)}"
          end
        rescue
          error ->
            if retries > 0 do
              Process.sleep(50)
              ensure_workspace_seeded!(workspace_uri, retries - 1)
            else
              reraise error, __STACKTRACE__
            end
        end

      _ ->
        :ok
    end
  end

  describe "Bug 1: Repo database config" do
    test "EzagentCore.Repo has a non-nil :database setting at runtime" do
      db = Application.get_env(:ezagent_core, EzagentCore.Repo)[:database]

      assert is_binary(db) and db != "",
             """
             EzagentCore.Repo[:database] is empty. PR 1 regression — plain
             mix tasks fail because runtime.exs isn't always evaluated.
             config/dev.exs must keep a compile-time default; runtime.exs
             still overrides for $EZAGENT_HOME / releases.
             """
    end

    test "Repo uses PostgreSQL with an explicit database name" do
      config = Application.get_env(:ezagent_core, EzagentCore.Repo)

      assert EzagentCore.Repo.__adapter__() == Ecto.Adapters.Postgres
      assert is_binary(config[:database]) and config[:database] != ""
    end
  end

  describe "Bug 2: Tailwind compiled bundle has shadcn-style classes" do
    @css_path Path.expand("../priv/static/assets/css/app.css", __DIR__)

    test "compiled app.css exists" do
      assert File.exists?(@css_path),
             "Expected compiled tailwind bundle at #{@css_path}. Run `mix tailwind ezagent_web --minify`."
    end

    test "bundle contains a class that only appears in domain_ui components" do
      content = File.read!(@css_path)

      # `.bg-zinc-900` is used by EzagentDomainUi.Components button variant
      # "primary" (apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex).
      # If Tailwind didn't scan domain_ui/lib, this class won't be in
      # the bundle.
      assert String.contains?(content, "bg-zinc-900"),
             """
             priv/static/assets/css/app.css is missing `bg-zinc-900` —
             the primary-button color from EzagentDomainUi.Components.

             Tailwind likely didn't @source the domain UI paths.
             Check apps/ezagent_web/assets/css/app.css for:
               @source "../../../ezagent_domain_ui/lib"

             Then rerun `mix tailwind ezagent_web --minify`.
             """
    end
  end

  describe "Bug 3: AutoDerive returns non-empty for foundational Kinds" do
    test "list_instances(:user) finds admin user" do
      instances = EzagentDomainUi.AutoDerive.list_instances(:user)

      assert length(instances) > 0,
             """
             EzagentDomainUi.AutoDerive.list_instances(:user) returned []
             but entity://system/user/admin should be live in the registry. Check
             the state-field accessors (:kind vs :kind_module,
             :state vs :slices) in apps/ezagent_domain_ui/lib/.../auto_derive.ex.
             """

      uris = Enum.map(instances, &URI.to_string(&1.uri))
      assert "entity://system/user/admin" in uris
    end

    test "list_instances(:session) is non-empty and returns well-formed session URIs" do
      # Bug-3 invariant: AutoDerive.list_instances(:session) must return a
      # NON-EMPTY, correctly-parsed list. The original bug read the wrong state
      # fields (`:kind` vs `:kind_module`, `:state` vs `:slices`) and didn't
      # parse the stored string URI → [] for EVERY Kind.
      #
      # What this test must NOT do is assert against SHARED MUTABLE STATE.
      # Two prior "fixes" asserted the system SEED session appears in the
      # registry, but list_instances(:session) does an UN-SCOPED
      # `Registry.select` across ALL tenants (see AutoDerive), and the seed is
      # an ephemeral DynSup child that sibling async suites terminate/respawn
      # concurrently — so asserting that specific seed raced no matter how long
      # the retry ran (the #184/#189 flake that survived both fixes precisely
      # because each was only ever validated in isolation, which by
      # construction cannot reproduce a concurrent-umbrella race). Creating a
      # session THIS test owns instead is blocked here: the bare genesis cap
      # only ADOPTS the pre-seeded session — CREATING a new one needs signed
      # workspace-grant caps under Path A cap-signing (out of scope for a smoke
      # test; a create attempt returns `{:error, :invalid_cap_signature}`).
      #
      # Regression-catching invariant that does NOT depend on any one session
      # surviving: the list is NON-EMPTY and every element is a well-formed
      # session `%URI{}`. Under the concurrent umbrella dozens of sibling
      # sessions keep it non-empty (robust to any single one being reaped); in
      # isolation the boot seed does. It can only be empty if the field-accessor
      # regression returns [] — exactly the bug we guard. Best-effort adopt the
      # seed first so the isolation (single-run) case is guaranteed ≥1, then
      # bounded-retry so a freak all-down instant can't flake it — only a
      # persistently-empty result (the real regression) fails.
      #
      # NOTE: `list_instances(:user)` (deterministic — admin is a permanent
      # static entity) already pins the same field-accessor code path against
      # a specific expected URI; this test adds the SESSION-scheme coverage
      # without the ephemeral-session raciness.
      _ =
        create_session_via_workspace("default", Ezagent.Entity.User.admin_uri(),
          template_name: "default"
        )

      instances =
        Enum.reduce_while(1..40, [], fn _i, _acc ->
          got = EzagentDomainUi.AutoDerive.list_instances(:session)
          if got != [], do: {:halt, got}, else: Process.sleep(25) && {:cont, got}
        end)

      assert instances != [],
             "list_instances(:session) returned [] after bounded retry — the Bug-3 " <>
               "field-accessor regression (wrong :kind/:state fields, or unparsed " <>
               "string URI) is back."

      # Second half of Bug-3: every element must be a well-formed session URI,
      # i.e. the stored string URI was parsed (not left mangled).
      for inst <- instances do
        assert %URI{scheme: "session"} = inst.uri,
               "list_instances(:session) yielded a non-session/mangled URI: #{inspect(inst.uri)}"
      end
    end

    test "instance_detail/1 returns a populated map for entity://system/user/admin" do
      {:ok, detail} =
        EzagentDomainUi.AutoDerive.instance_detail(Ezagent.URI.new!("entity://system/user/admin"))

      assert detail.kind_module == "Ezagent.Entity.User"
      assert is_map(detail.slices)
      # admin User carries the all-cap identity slice + chat slice
      assert Map.has_key?(detail.slices, :identity) or Map.has_key?(detail.slices, :session)
      assert is_list(detail.behaviors)
    end
  end
end

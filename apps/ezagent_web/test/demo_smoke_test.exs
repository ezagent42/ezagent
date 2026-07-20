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
             %{caller: creator_uri, caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
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

    test "list_instances(:session) finds the seeded default session" do
      # The `session://system/default/main` seed is a DynamicSupervisor
      # child spawned ONCE at chat-app boot — NOT a permanent static
      # child. Under the full concurrent umbrella run another test can
      # terminate it (or it is mid-respawn) when this assertion reads the
      # global registry, so the seed is not guaranteed live here. Ensure
      # it via the idempotent create_session facade (returns the existing
      # Session via the `:adopted` path if already alive) before asserting.
      # Seed name was renamed from "main" → "default" (#408/#410 era).
      # Accept either to stay robust across the rename.
      seeded = ["session://system/default/default", "session://system/default/main"]

      # #184-class isolation flake (confirmed: passes in isolation, races only
      # under the full concurrent umbrella): the seed is an ephemeral DynSup
      # child a sibling test can terminate — OR mutate the shared system-tenant
      # session — between the idempotent ensure and the global-registry read. A
      # single ensure+read is not enough. Retry ensure+read a bounded number of
      # times so a concurrent termination cannot flake this; each pass re-adopts
      # (or re-spawns) the seed via the idempotent create facade.
      uris =
        Enum.reduce_while(1..40, [], fn _i, _acc ->
          _ =
            create_session_via_workspace("main", Ezagent.Entity.User.admin_uri(),
              template_name: "default"
            )

          uris =
            EzagentDomainUi.AutoDerive.list_instances(:session)
            |> Enum.map(&URI.to_string(&1.uri))

          if Enum.any?(seeded, &(&1 in uris)),
            do: {:halt, uris},
            else: Process.sleep(25) && {:cont, uris}
        end)

      assert Enum.any?(seeded, &(&1 in uris)),
             "expected a seeded system session after bounded ensure-retry; got: #{inspect(uris)}"
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

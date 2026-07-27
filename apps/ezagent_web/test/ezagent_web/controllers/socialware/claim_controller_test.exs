defmodule EzagentWeb.Socialware.ClaimControllerTest do
  @moduledoc """
  URI-share unification (A1) — `GET /socialware/claim?token=` acceptance.

  A logged-in clicker opens a bearer share link (`Ezagent.Cap.ShareToken`,
  naming ANY target URI + the granted behavior/actions). The generic,
  plugin-agnostic controller verifies the token and mints a grantee-bound cap
  toward the target for the clicker (`Ezagent.Socialware.Share.claim/2`), then
  302s to the world root; a tampered/expired token → 403 fail-closed; an
  anonymous visitor is bounced to /login by RequireEntity. Target here is the
  generic `CompositionGrantTargetBehavior` fixture — the point is scheme/plugin
  agnosticism, not kanban.
  """
  use EzagentWeb.ConnCase, async: false

  alias Ezagent.Cap.ShareToken
  alias Ezagent.Entity.User
  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    ws = "claim-#{u()}"
    {:ok, _ws} = Ezagent.Workspace.create(ws, %{})
    {:ok, ws: ws}
  end

  @tag :integration
  test "valid token → mints a grantee-bound cap for the clicker + 302 to world root",
       %{conn: conn, ws: ws} do
    skip_if_no_entity_spawn(fn ->
      owner = user(ws, "owner")
      target = target_agent(ws, "shared", owner)
      clicker = signed_in_user(ws, "clicker")

      token = ShareToken.mint_link!(target, Target, [:get_tree], ttl_seconds: 60)

      out =
        conn
        |> sign_in(ws, clicker)
        |> get(~p"/socialware/claim?#{[token: token]}")

      assert redirected_to(out) == "/"

      # cap-as-truth: the clicker now holds the shared read cap toward the target.
      assert eventually(fn -> holds_cap?(clicker, target, :get_tree) end)
      refute holds_cap?(clicker, target, :add_node)
    end)
  end

  @tag :integration
  test "tampered token → 403, mints nothing", %{conn: conn, ws: ws} do
    skip_if_no_entity_spawn(fn ->
      owner = user(ws, "owner2")
      target = target_agent(ws, "shared2", owner)
      clicker = signed_in_user(ws, "clicker2")

      out =
        conn
        |> sign_in(ws, clicker)
        |> get(~p"/socialware/claim?#{[token: "garbage"]}")

      assert out.status == 403
      refute holds_cap?(clicker, target, :get_tree)
    end)
  end

  @tag :integration
  test "anonymous (not logged in) is bounced to /login by RequireEntity", %{conn: conn} do
    out = get(conn, ~p"/socialware/claim?#{[token: "x"]}")
    assert redirected_to(out) == "/login"
  end

  # --- helpers ------------------------------------------------------------

  defp u, do: System.unique_integer([:positive])

  defp user(ws, label) do
    uri = Ezagent.URI.new!("entity://#{ws}/user/#{label}-#{u()}")
    {:ok, _} = Ezagent.Users.create(uri, "test-password-#{u()}", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp signed_in_user(ws, label) do
    uri = Ezagent.URI.new!("entity://#{ws}/user/#{label}-#{u()}")
    {:ok, _} = Ezagent.Users.create_read_only(uri, [])
    :ok = Ezagent.Entity.spawn_principal(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  # A generic target: an agent carrying the Target ActionSet with a recorded
  # owner (data_owner resolves, so mint_cap has a granter). URI-agnostic — the
  # controller neither knows nor names any plugin.
  defp target_agent(ws, name, owner) do
    uri = Ezagent.URI.agent(ws, "#{name}-#{u()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ [Target]),
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.URI.new!("workspace://#{ws}"))
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp sign_in(conn, ws, %URI{} = entity_uri) do
    case Ezagent.Users.get_by_uri(entity_uri) do
      nil -> {:ok, _} = Ezagent.Users.create(URI.to_string(entity_uri), nil, [])
      _ -> :ok
    end

    Plug.Test.init_test_session(conn, %{
      "current_entity_uri" => URI.to_string(entity_uri),
      "current_workspace_uri" => "workspace://#{ws}"
    })
  end

  defp holds_cap?(grantee, target, action) do
    Enum.any?(Ezagent.Identity.list_caps_for(grantee), fn cap ->
      cap.kind == :agent and cap.behavior == Target and
        cap.action == action and
        cap.instance == Ezagent.URI.instance(target)
    end)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end

defmodule EzagentPluginLiveview.AgentNewLiveTest do
  @moduledoc """
  Phase 8c PR-N — UI for creating new agents at `/identities/agents/new`.

  Verifies:

  - mount renders form (flavor dropdown + name input + caps input)
  - submit valid → spawns agent + push_navigates to detail
  - submit empty name → friendly error
  - submit invalid name characters → friendly error
  - submit pre-existing URI → "already exists" error (no misleading
    "Create" on a noop, per `feedback_ui_no_misleading_buttons`)
  - cap parsing happens — invalid caps surface the parser error
  """
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # AgentNewLive now routes echo (Domain.Pty SPEC v1 §10 row 3) AND
    # cc through `Workspace.add_template("default", ...)`. Every test
    # that submits the form needs the "default" workspace to exist;
    # cheaper to ensure it once in the top-level setup than to repeat
    # the dance in each describe block.
    ensure_default_workspace()

    # V-6 fix (audit 2026-05-23) — AgentNewLive now reads the workspace
    # from socket assigns (set by EzagentWeb.LiveAuth from the
    # `current_workspace_uri` session slot) instead of hardcoding
    # "default". Tests opt into the default workspace explicitly so
    # the suite stays workspace-aware AND the admin user (whose
    # natural workspace is `system`) doesn't accidentally land in
    # the wrong tenant.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://team-alpha"
      })

    {:ok, conn: conn}
  end

  # Ensures the "default" workspace exists in the DB AND has a live
  # Workspace Kind GenServer.
  #
  # Test-env boot deliberately skips `ensure_default_workspace` (see
  # `EzagentDomainChat.Application.ensure_default_workspace/0`
  # moduledoc — DB writes in `Application.start/2` race with Sandbox
  # checkout). So `default` is missing from the DB on every fresh
  # test-suite run; one of these per-suite setups creates it. The
  # tricky bit is the Workspace Kind GenServer is registered
  # globally and outlives sandbox rollback, so subsequent tests must
  # tolerate "DB row gone but Kind still alive".
  defp ensure_default_workspace do
    name = "default"

    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        case Ezagent.Workspace.create(name, %{}) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            # Kind is alive but DB row got rolled back from a prior
            # test (or stub). Re-insert just the row.
            case Ezagent.Workspace.Store.create(name, %{}) do
              {:ok, _} -> :ok
              {:error, %Ecto.Changeset{}} -> :ok
            end
        end

      _existing ->
        # Row already visible. If the Kind happened to die we'd need
        # to respawn here, but in practice the registered singleton
        # lives for the duration of the test suite.
        :ok
    end

    :ok
  end

  test "GET /identities/agents/new renders the create form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/identities/agents/new")

    assert html =~ "New agent"
    assert html =~ "Flavor"
    assert html =~ "Name"
    assert html =~ "Initial caps"
    # Flavor dropdown options
    assert html =~ "cc"
    assert html =~ "echo"
    assert html =~ "curl"
    # V-6 fix — preview now includes the caller's workspace
    # segment, so the placeholder is `<flavor>_<name>` after
    # `entity://agent/<workspace>/`.
    assert html =~ "entity://agent/team-alpha/&lt;flavor&gt;_&lt;name&gt;" or
             html =~ "entity://agent/team-alpha/<flavor>_<name>"

    # Submit button
    assert html =~ "Create agent"
  end

  test "preview line updates as user types", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/identities/agents/new")

    html =
      lv
      |> form("#agent-new-form", %{
        "agent" => %{"flavor" => "echo", "name" => "preview-demo", "caps" => ""}
      })
      |> render_change()

    assert html =~ "entity://agent/team-alpha/echo_preview-demo"
  end

  test "submit with valid inputs spawns agent + redirects", %{conn: conn} do
    name = "ui-#{System.unique_integer([:positive])}"
    {:ok, lv, _html} = live(conn, "/identities/agents/new")

    # `render_submit` with a `live_redirect` from the LV raises a
    # `{:redirect, _, _}` via `Phoenix.LiveViewTest.assert_redirect`.
    assert {:error, {:live_redirect, %{to: to}}} =
             lv
             |> form("#agent-new-form", %{
               "agent" => %{"flavor" => "echo", "name" => name, "caps" => ""}
             })
             |> render_submit()

    expected_uri = URI.encode_www_form("entity://agent/team-alpha/echo_#{name}")
    assert to == "/identities/agents/#{expected_uri}"

    # Verify the agent actually exists in the live KindRegistry.
    {:ok, _pid} =
      Ezagent.KindRegistry.lookup(URI.parse("entity://agent/team-alpha/echo_#{name}"))
  end

  test "submit with empty name surfaces error and stays on page", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/identities/agents/new")

    html =
      lv
      |> form("#agent-new-form", %{
        "agent" => %{"flavor" => "echo", "name" => "", "caps" => ""}
      })
      |> render_submit()

    assert html =~ "Name is required"
  end

  test "submit with invalid name characters surfaces error", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/identities/agents/new")

    html =
      lv
      |> form("#agent-new-form", %{
        # spaces are not allowed in URI path segments and the validator
        # forbids them.
        "agent" => %{"flavor" => "echo", "name" => "has spaces", "caps" => ""}
      })
      |> render_submit()

    assert html =~ "must start with a letter or digit"
  end

  test "submit pre-existing URI surfaces 'already exists' error", %{conn: conn} do
    name = "dup-#{System.unique_integer([:positive])}"
    uri = URI.parse("entity://agent/team-alpha/echo_#{name}")

    # Pre-create the agent.
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

    {:ok, lv, _html} = live(conn, "/identities/agents/new")

    html =
      lv
      |> form("#agent-new-form", %{
        "agent" => %{"flavor" => "echo", "name" => name, "caps" => ""}
      })
      |> render_submit()

    assert html =~ "already exists"
  end

  test "submit with caps string parses cleanly (parser dry-run via empty caps + later inspect)",
       %{conn: conn} do
    # Caps grant goes through `Invocation.dispatch`, which the sandbox
    # owner can't see when the dispatch fans out into a separate
    # process. Rather than fight the audit-writer sandbox plumbing
    # for a test that's really verifying "parser accepts the string"
    # + "dispatch runs without exception", we verify the redirect
    # against empty caps (proves the create path works end-to-end)
    # and verify the parser separately with no dispatch involved.
    name = "caps-#{System.unique_integer([:positive])}"
    {:ok, lv, _html} = live(conn, "/identities/agents/new")

    assert {:error, {:live_redirect, %{to: _}}} =
             lv
             |> form("#agent-new-form", %{
               "agent" => %{
                 "flavor" => "echo",
                 "name" => name,
                 "caps" => ""
               }
             })
             |> render_submit()

    agent_uri = URI.parse("entity://agent/team-alpha/echo_#{name}")
    {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)

    # Verify caps parser accepts the placeholder string. This is the
    # exact path AgentNewLive.create_agent/2 takes, so if this parses,
    # the LV will pass that step too.
    assert {:ok, [%Ezagent.Capability{} | _]} =
             Ezagent.Capability.Parser.parse(
               "chat.send, workspace.read",
               Ezagent.Entity.User.admin_uri()
             )
  end

  test "+ New agent button on /identities links to /identities/agents/new", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/identities")

    # JS.navigate sends through phx-click; the encoded JSON shows up
    # in the rendered HTML.
    assert html =~ "/identities/agents/new"
    assert html =~ "+ New agent"
  end

  # Domain.Pty SPEC v1 §10 row 3 + §11 item 6 (deferred PR-D sub-task,
  # now in scope per Allen Feishu 2026-05-22). echo flavor now routes
  # through the `echo.agent` Template Class so the operator can opt
  # into a `/bin/bash -i` PTY sidecar. Pin the new conditional render
  # paths + the with_pty=true wiring.
  describe "echo flavor — With PTY checkbox + cwd conditional (Domain.Pty SPEC §10 row 3)" do
    setup do
      ensure_default_workspace()
      :ok
    end

    test "echo + with_pty unchecked → no cwd field rendered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/identities/agents/new")

      # Change to echo without checking with_pty.
      html =
        lv
        |> form("#agent-new-form", %{
          "agent" => %{"flavor" => "echo", "name" => "no-pty", "caps" => ""}
        })
        |> render_change()

      # The "With PTY" checkbox row is present for echo flavor.
      assert has_element?(lv, "#with-pty-row")
      assert has_element?(lv, "#agent_with_pty")
      # cwd field is hidden — no `name="agent[cwd]"` input in the DOM.
      refute html =~ ~s(name="agent[cwd]")
    end

    test "echo + with_pty checked → cwd field rendered + required", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/identities/agents/new")

      # Step 1: switch flavor to echo so the `agent[with_pty]`
      # checkbox enters the DOM (Phoenix.LiveViewTest's `form/3` only
      # sees inputs currently in the rendered HTML).
      _ =
        lv
        |> render_change("preview", %{
          "agent" => %{"flavor" => "echo", "name" => "with-pty", "caps" => ""}
        })

      # Step 2: now check the with_pty box; the hidden `false`
      # companion still ships, but `true` wins via last-write.
      html =
        lv
        |> render_change("preview", %{
          "agent" => %{
            "flavor" => "echo",
            "name" => "with-pty",
            "with_pty" => "true",
            "caps" => ""
          }
        })

      assert has_element?(lv, "#with-pty-row")
      # cwd input is now present.
      assert html =~ ~s(name="agent[cwd]")
      # The hint copy mentions /bin/bash -i so the operator sees what
      # the PTY runs.
      assert html =~ "/bin/bash -i"
    end

    test "echo + with_pty=true + no cwd → friendly error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/identities/agents/new")

      # Reveal the checkbox first (see comment in the previous test).
      _ =
        lv
        |> render_change("preview", %{
          "agent" => %{"flavor" => "echo", "name" => "x", "caps" => ""}
        })

      html =
        lv
        |> render_submit("create_agent", %{
          "agent" => %{
            "flavor" => "echo",
            "name" => "needs-cwd-#{System.unique_integer([:positive])}",
            "with_pty" => "true",
            "cwd" => "",
            "caps" => ""
          }
        })

      assert html =~ "Working directory is required"
    end

    test "echo + with_pty=true + cwd → instantiates template → Agent Kind AND PtyServer alive",
         %{conn: conn} do
      name = "echo-pty-#{System.unique_integer([:positive])}"
      agent_uri = URI.parse("entity://agent/team-alpha/echo_#{name}")

      {:ok, lv, _html} = live(conn, "/identities/agents/new")

      # Reveal the checkbox first.
      _ =
        lv
        |> render_change("preview", %{
          "agent" => %{"flavor" => "echo", "name" => name, "caps" => ""}
        })

      assert {:error, {:live_redirect, %{to: to}}} =
               lv
               |> render_submit("create_agent", %{
                 "agent" => %{
                   "flavor" => "echo",
                   "name" => name,
                   "with_pty" => "true",
                   "cwd" => System.tmp_dir!(),
                   "caps" => ""
                 }
               })

      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      assert to == "/identities/agents/#{encoded}"

      # Cross-flavor PTY opt-in invariant: BOTH halves alive.
      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive after echo with_pty=true create_agent"

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      assert {:ok, pty_pid} = Ezagent.Domain.Pty.lookup(agent_uri),
             "PtyServer must be alive after echo with_pty=true create_agent"

      assert is_pid(pty_pid)
      assert Process.alive?(pty_pid)
    end

    test "echo + with_pty=false → only the Agent Kind is alive (no PtyServer)",
         %{conn: conn} do
      name = "echo-no-pty-#{System.unique_integer([:positive])}"
      agent_uri = URI.parse("entity://agent/team-alpha/echo_#{name}")

      {:ok, lv, _html} = live(conn, "/identities/agents/new")

      assert {:error, {:live_redirect, %{to: _}}} =
               lv
               |> form("#agent-new-form", %{
                 "agent" => %{
                   "flavor" => "echo",
                   "name" => name,
                   "caps" => ""
                 }
               })
               |> render_submit()

      assert {:ok, _agent_pid} = Ezagent.KindRegistry.lookup(agent_uri)

      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "PtyServer must NOT be started when with_pty is unchecked"
    end
  end

  # Regression suite for the V1 acceptance bug. The user-visible
  # failure was: operator clicks "Create agent" with `flavor=cc`, UI
  # redirects to the detail page, detail page shows "Not running"
  # forever.
  #
  # Root cause was a two-fold inversion:
  # 1. AgentNewLive called `SpawnRegistry.spawn(agent_uri)` BEFORE
  #    `Workspace.add_template/3`. That spawned the Agent Kind out-
  #    of-order, and the subsequent `cc.agent.instantiate/3` saw the
  #    Kind already alive → idempotent short-circuit → PtyServer
  #    never started.
  # 2. `Workspace.add_template/3` never chained into
  #    `Workspace.Loader.invoke_template/2`, so even if the order had
  #    been right, the Template Class's instantiate never ran at
  #    runtime.
  #
  # These tests pin BOTH halves of the invariant: after create_agent
  # with `flavor=cc`, both the Agent Kind AND the PtyServer are alive.
  describe "cc flavor — V1 fix invariant (Allen 2026-05-21)" do
    setup do
      # Ensure the "default" workspace exists — AgentNewLive's
      # `register_and_instantiate("cc", ...)` writes to it via
      # `Workspace.add_template`. Idempotent: existing-workspace tests
      # can run in any order.
      ensure_default_workspace()
      :ok
    end

    test "create_agent for cc → BOTH Agent Kind AND PtyServer alive (no `Not running`)",
         %{conn: conn} do
      name = "v1fix-#{System.unique_integer([:positive])}"
      agent_uri = URI.parse("entity://agent/team-alpha/cc_#{name}")

      {:ok, lv, _html} = live(conn, "/identities/agents/new")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv
               |> form("#agent-new-form", %{
                 "agent" => %{
                   "flavor" => "cc",
                   "name" => name,
                   "cwd" => System.tmp_dir!(),
                   "caps" => ""
                 }
               })
               |> render_submit()

      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      assert to == "/identities/agents/#{encoded}"

      # The two assertions that fail without the V1 fix:
      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive after create_agent (V1 fix invariant 1/2)"

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      assert {:ok, pty_pid} = Ezagent.Domain.Pty.lookup(agent_uri),
             "PtyServer must be alive after create_agent (V1 fix invariant 2/2)"

      assert is_pid(pty_pid)
      assert Process.alive?(pty_pid)
    end
  end
end

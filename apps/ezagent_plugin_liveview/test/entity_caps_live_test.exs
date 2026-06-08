defmodule EzagentPluginLiveview.EntityCapsLiveTest do
  @moduledoc """
  Phase 8c PR-G — EntityCapsLive serves both user + agent cap surfaces.

  Invariants tested:

  - `/identities/users/:uri/caps` still renders (legacy route preserved
    after rename from UserCapsLive).
  - `/identities/agents/:uri/caps` renders for a live Agent Kind and
    exposes the grant form.
  - Grant + revoke round-trip works against a live Agent (agents
    carry `Ezagent.Behavior.Identity` per
    `Ezagent.Entity.Agent.behaviors/0`).
  """
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # The agents these tests spawn live in `entity://team-alpha/agent/…`.
    # IdentitiesLive filters its directory to the operator's current
    # workspace (Task #55), so the session must view team-alpha — without
    # it the admin lands in `workspace://system` and the team-alpha agent
    # is filtered out of the listing. (post-lifecycle remediation.)
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://team-alpha"
      })

    {:ok, conn: conn}
  end

  test "GET /identities/users/:uri/caps still renders (legacy alias preserved)", %{conn: conn} do
    admin_uri_str = URI.to_string(Ezagent.Entity.User.admin_uri())
    encoded = URI.encode_www_form(admin_uri_str)

    {:ok, _lv, html} = live(conn, "/identities/users/#{encoded}/caps")
    assert html =~ "Caps for"
    assert html =~ admin_uri_str
    assert html =~ "Grant new cap"
  end

  test "GET /identities/agents/:uri/caps renders grant form for a live agent", %{conn: conn} do
    agent_uri =
      URI.parse(
        "entity://team-alpha/agent/test_caps-render-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    {:ok, _lv, html} = live(conn, "/identities/agents/#{encoded}/caps")

    assert html =~ "Caps for"
    assert html =~ URI.to_string(agent_uri)
    assert html =~ "Grant new cap"
    # A fresh agent is provisioned with exactly one structural baseline
    # cap at spawn: the owner-derived self-Identity cap that lets it read
    # its own caps (PR-OWN-3, asserted by Identity.create/1's unit test).
    # The caps table therefore renders that row, not the empty state.
    assert html =~ "Ezagent.Behavior.Identity"
    refute html =~ "No caps. Grant one above."
  end

  test "grant + revoke round-trip works on a live agent", %{conn: conn} do
    agent_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_caps-grant-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}/caps")

    # Grant a cap.
    lv
    |> form("#grant-cap-form", %{
      "grant" => %{"kind" => "echo", "behavior" => "any", "instance" => "any"}
    })
    |> render_submit()

    html = render(lv)
    assert html =~ "Granted cap to"
    assert html =~ ":echo"

    # The agent now holds two caps: its structural self-Identity baseline
    # cap (provisioned at spawn, PR-OWN-3) plus the just-granted :echo
    # cap. Revoke every row (index 0 each time — the list re-renders and
    # shrinks) so the round-trip drains both and lands on the empty
    # state. (post-lifecycle remediation: the old test assumed a fresh
    # agent had zero caps, ignoring the baseline self-cap.)
    revoke_sel = "button[phx-click=\"revoke\"][phx-value-index=\"0\"]"

    revoke_all = fn revoke_all ->
      if has_element?(lv, revoke_sel) do
        lv |> element(revoke_sel) |> render_click()
        revoke_all.(revoke_all)
      end
    end

    revoke_all.(revoke_all)

    html = render(lv)
    assert html =~ "Revoked cap"
    assert html =~ "No caps. Grant one above."
  end

  describe "action-axis grant (SPEC 2026-05-27 §3.6.1(b) — action selector dropdown)" do
    # The grant form gains an action `<select>` populated from the
    # TARGET behavior's `actions/0` (trustworthy: declared in compiled
    # code, not user-supplied). Default `:any` is preserved (a
    # behavior-wildcard, the pre-PR behaviour). Selecting a concrete
    # action mints a NARROW cap carrying that action — so a member can
    # be granted exactly one action of a multi-action behavior without
    # the over-grant the action-axis SPEC closes.

    test "action selector lists the resolved behavior's actions + :any", %{conn: conn} do
      agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_caps-actsel-#{System.unique_integer([:positive])}"
        )

      {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")
      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}/caps")

      # Type a concrete behavior → the action selector recomputes from
      # `Ezagent.Behavior.Echo.actions/0`.
      html =
        lv
        |> form("#grant-cap-form", %{
          "grant" => %{
            "kind" => "echo",
            "behavior" => "echo",
            "instance" => "any",
            "action" => "any"
          }
        })
        |> render_change()

      # `:any` is always present (default / wildcard option).
      assert html =~ ~s(value="any")
      # Echo's concrete actions show up as options.
      assert html =~ ~s(value="say")
      assert html =~ ~s(value="receive")
    end

    test "selecting a concrete action grants a cap carrying that action", %{conn: conn} do
      agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_caps-actgrant-#{System.unique_integer([:positive])}"
        )

      {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")
      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}/caps")

      grant_form =
        form(lv, "#grant-cap-form", %{
          "grant" => %{
            "kind" => "echo",
            "behavior" => "echo",
            "instance" => "any",
            "action" => "any"
          }
        })

      # Real interaction: typing the behavior fires phx-change, which
      # populates the action selector from `Ezagent.Behavior.Echo.actions/0`.
      render_change(grant_form)

      # Now `:say` is a valid option — pick it and submit.
      form(lv, "#grant-cap-form", %{
        "grant" => %{
          "kind" => "echo",
          "behavior" => "echo",
          "instance" => "any",
          "action" => "say"
        }
      })
      |> render_submit()

      assert render(lv) =~ "Granted cap to"

      caps = Ezagent.Identity.list_caps_for(agent_uri) |> MapSet.to_list()

      # codex review MED: the cap is stored under the resolved Behavior
      # MODULE (not the `:echo` atom), so it actually matches dispatch
      # `required_caps/0` instead of being an inert narrow grant.
      granted =
        Enum.find(caps, fn c ->
          c.behavior == Ezagent.Behavior.Echo and Ezagent.Capability.action_of(c) == :say
        end)

      assert granted, "expected a cap with action: :say, got: #{inspect(caps)}"

      # The granted concrete-action cap AUTHORIZES the matching dispatch
      # need (Echo :say → `cap(:echo, Ezagent.Behavior.Echo, :say)`) but
      # NOT a different action on the same behavior — proving the action
      # axis is load-bearing AND the behavior axis matches dispatch.
      say_need = %{
        kind: :echo,
        behavior: Ezagent.Behavior.Echo,
        action: :say,
        instance: agent_uri,
        workspace_uri: Ezagent.URI.entity_workspace_uri(agent_uri)
      }

      receive_need = %{say_need | action: :receive}

      assert Ezagent.Capability.matches?(granted, say_need)
      refute Ezagent.Capability.matches?(granted, receive_need)
    end

    test "a forged action NOT in the behavior's actions/0 is REJECTED (no atom minted)", %{
      conn: conn
    } do
      # codex review HIGH — a crafted submit bypassing the <select> sends
      # an action string the behavior never declared. It must be rejected
      # before any cap is built and WITHOUT minting a new atom.
      agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_caps-forge-#{System.unique_integer([:positive])}"
        )

      {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")
      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}/caps")

      forged = "totally_unknown_forged_action_#{System.unique_integer([:positive])}"
      # The atom must NOT exist before the submit.
      assert_raise ArgumentError, fn -> String.to_existing_atom(forged) end

      # Submit RAW params directly to the form's phx-submit event (the
      # `form/3` helper would client-side-validate the <select> options;
      # a real malicious client bypasses that, so we drive the event
      # payload straight through to exercise the SERVER-side guard).
      render_submit(element(lv, "#grant-cap-form"), %{
        "grant" => %{
          "kind" => "echo",
          "behavior" => "echo",
          "instance" => "any",
          "action" => forged
        }
      })

      html = render(lv)
      assert html =~ "invalid action"
      refute html =~ "Granted cap to"
      # No new atom was minted by the rejected submit.
      assert_raise ArgumentError, fn -> String.to_existing_atom(forged) end

      caps = Ezagent.Identity.list_caps_for(agent_uri) |> MapSet.to_list()

      refute Enum.any?(caps, fn c -> Atom.to_string(Ezagent.Capability.action_of(c)) == forged end)
    end

    test "a forged behavior name is REJECTED without minting an alias atom (codex HIGH)", %{
      conn: conn
    } do
      agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_caps-fbehav-#{System.unique_integer([:positive])}"
        )

      {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")
      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}/caps")

      # Use a lower_snake_case forged name so we can predict EXACTLY the
      # alias atom `resolve_behavior_module/1` would build: it splits on
      # "_" and `String.capitalize/1`s each segment, joins, and prefixes
      # `Elixir.Ezagent.Behavior.`. `zz_forged_NNN` → `ZzForgedNNN`.
      uniq = System.unique_integer([:positive])
      forged_behavior = "zz_forged_#{uniq}"

      normalized =
        forged_behavior
        |> String.split("_")
        |> Enum.map_join("", &String.capitalize/1)

      forged_module = "Elixir.Ezagent.Behavior." <> normalized
      # The normalized alias atom must not exist yet.
      assert_raise ArgumentError, fn -> String.to_existing_atom(forged_module) end

      render_submit(element(lv, "#grant-cap-form"), %{
        "grant" => %{
          "kind" => "echo",
          "behavior" => forged_behavior,
          "instance" => "any",
          "action" => "any"
        }
      })

      html = render(lv)
      assert html =~ "unknown behavior"
      refute html =~ "Granted cap to"
      # The rejected submit must NOT have allocated the alias atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(forged_module) end
    end

    test ":any action still grants a behavior-wildcard cap (default preserved)", %{conn: conn} do
      agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_caps-anygrant-#{System.unique_integer([:positive])}"
        )

      {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")
      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}/caps")

      lv
      |> form("#grant-cap-form", %{
        "grant" => %{
          "kind" => "echo",
          "behavior" => "echo",
          "instance" => "any",
          "action" => "any"
        }
      })
      |> render_submit()

      assert render(lv) =~ "Granted cap to"

      caps = Ezagent.Identity.list_caps_for(agent_uri) |> MapSet.to_list()

      assert Enum.any?(caps, fn c ->
               c.behavior == Ezagent.Behavior.Echo and Ezagent.Capability.action_of(c) == :any
             end)
    end
  end

  test "/identities lists agents with a Caps link", %{conn: conn} do
    agent_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_caps-list-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")

    {:ok, _lv, html} = live(conn, "/identities")

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    assert html =~ "/identities/agents/#{encoded}/caps"
  end
end

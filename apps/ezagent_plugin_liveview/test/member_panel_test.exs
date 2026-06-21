defmodule EzagentPluginLiveview.Admin.MemberPanelTest do
  @moduledoc """
  V1 UI SPEC §2C — render tests for the redesigned `MemberPanel`.

  Asserts the structural contract of the §2C.3 redesign:

  - ONE unified member list — members and ex-"floating" agents render
    identically (same `<li>` shape, same `<.avatar>`, same online dot).
  - NO "FLOATING AGENTS" `<select>` section (deleted per §2C.2).
  - An Invite button that opens a `<.modal>` carrying the "Add existing"
    `uri_picker` + a "Create new agent" link to `/identities/agents/new`.
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EzagentPluginLiveview.Admin.MemberPanel

  defp render_panel(assigns) do
    rendered_to_string(~H"""
    <MemberPanel.member_panel
      members={@members}
      display_map={@display_map}
      invite_open={@invite_open}
      invite_options={@invite_options}
    />
    """)
  end

  defp base_assigns(overrides) do
    merged =
      Map.merge(
        %{members: [], display_map: %{}, invite_open: false, invite_options: []},
        Map.new(overrides)
      )

    # These are pure render tests — no DB. `display_for/2` only touches
    # the DB (`EntityPresenter.display/1`) when a member URI is absent
    # from `display_map`. Auto-populate the map for every member URI so
    # the component renders without an Ecto sandbox unless the test
    # supplied its own map.
    case merged.display_map do
      map when map_size(map) == 0 ->
        %{merged | display_map: Map.new(merged.members, &{&1.uri, &1.uri})}

      _ ->
        merged
    end
  end

  describe "unified member list (SPEC §2C.3)" do
    test "renders a user member and an ex-floating agent member identically" do
      # A floating agent, post-redesign, is JUST a member added ad-hoc.
      # Both rows must be the SAME shape — an entity avatar, the display
      # name, the URI, an online dot. Nothing flags "this one was
      # floating".
      pty_agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/pty-backed-#{System.unique_integer([:positive])}"
        )

      {:ok, _pty_pid} = Ezagent.Domain.Pty.start(pty_agent_uri, %{cwd: "/tmp", test_mode: true})
      on_exit(fn -> Ezagent.Domain.Pty.stop(pty_agent_uri) end)

      pty_agent_uri_str = URI.to_string(pty_agent_uri)

      members = [
        %{uri: "entity://team-alpha/user/admin", online: true, last_seen: nil},
        %{uri: pty_agent_uri_str, online: false, last_seen: nil}
      ]

      display_map = %{
        "entity://team-alpha/user/admin" => "Admin",
        pty_agent_uri_str => "PTY Agent"
      }

      html = render_panel(base_assigns(members: members, display_map: display_map))

      # One unified list container.
      assert html =~ ~s(id="session-members-table")
      refute html =~ ~s(id="session-members-empty")

      # Both members render — display name + URI.
      assert html =~ "Admin"
      assert html =~ "entity://team-alpha/user/admin"
      assert html =~ "PTY Agent"
      assert html =~ pty_agent_uri_str

      # Both rows carry a procedural avatar (the `<.avatar>` atom emits
      # a conic-gradient span). Two members → two avatar gradients.
      gradient_count =
        html |> String.split("conic-gradient") |> length() |> Kernel.-(1)

      assert gradient_count >= 2,
             "expected an <.avatar> per member row (>= 2 conic-gradients), got #{gradient_count}"

      # PTY-backed agent rows keep their per-row PTY button; the user
      # row does not get one. The agent URI deliberately has no flavor
      # prefix — the component gates on Domain.Pty state, not URI names.
      assert html =~ ~s(phx-click="switch_to_pty_for_agent")
      assert html =~ ~s(phx-value-agent="#{pty_agent_uri_str}")
    end

    test "empty member list shows the placeholder, not the table" do
      html = render_panel(base_assigns([]))

      assert html =~ ~s(id="session-members-empty")
      refute html =~ ~s(id="session-members-table")
      assert html =~ "No members yet"
    end
  end

  describe "FLOATING AGENTS section removed (SPEC §2C.2)" do
    test "no <select> floating-agent picker is rendered" do
      members = [%{uri: "entity://team-alpha/user/admin", online: true, last_seen: nil}]
      html = render_panel(base_assigns(members: members))

      # The old `<select name="agent_uri">` + its "Floating agents"
      # heading + the `add_floating_agent` change event are all gone.
      refute html =~ ~s(name="agent_uri")
      refute html =~ "Floating agents"
      refute html =~ "add_floating_agent"
      refute html =~ ~s(id="floating-agents-picker")
    end
  end

  describe "Invite modal (SPEC §2C.3)" do
    test "Invite button is present and opens the modal" do
      html = render_panel(base_assigns([]))

      assert html =~ ~s(id="invite-member-button")
      assert html =~ ~s(phx-click="open_invite_modal")
    end

    test "closed modal carries the hidden class; open modal does not" do
      closed = render_panel(base_assigns(invite_open: false))
      opened = render_panel(base_assigns(invite_open: true))

      # `<.modal>` adds `hidden` to the wrapper when `open` is false.
      [_, closed_modal_block | _] = String.split(closed, ~s(id="invite-member-modal"))
      assert closed_modal_block =~ "hidden"

      [_, opened_modal_block | _] = String.split(opened, ~s(id="invite-member-modal"))
      # The open modal's wrapper class list does not contain a bare
      # `hidden` token (the modal only adds it when closed).
      refute opened_modal_block
             |> String.split(">")
             |> hd()
             |> String.contains?(" hidden")
    end

    test "modal carries the Add-existing uri_picker + Create-new-agent link" do
      options = [
        %{uri: "entity://team-alpha/agent/cc_pick", label: "CC Pick", kind: :entity, flavor: "cc"}
      ]

      html = render_panel(base_assigns(invite_open: true, invite_options: options))

      # "Add existing" — a :single, entity-kind uri_picker submitting
      # `invite_member` with `member_uri`.
      assert html =~ ~s(phx-submit="invite_member")
      assert html =~ ~s(name="member_uri")
      assert html =~ ~s(phx-hook="UriPicker")
      assert html =~ ~s(data-mode="single")
      assert html =~ "entity://team-alpha/agent/cc_pick"

      # "Create new agent" — a link to the EXISTING AgentNewLive route,
      # not a rebuilt form.
      assert html =~ ~s(href="/identities/agents/new")
      assert html =~ ~s(id="invite-create-agent-link")
    end
  end
end

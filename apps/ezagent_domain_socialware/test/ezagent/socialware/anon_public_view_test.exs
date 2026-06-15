defmodule Ezagent.Socialware.PublicViewTest do
  @moduledoc """
  Issue #51 — `public_view` is a SessionTemplate-level config (spec §3.5, OQ-6).

  Both the fail-closed default (`public_view?/1` is `false` for an un-flagged
  session) AND the Template-flag resolution (a session whose materializing
  SessionTemplate declares `public_view: true` is viewable) are tested.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate}
  alias Ezagent.Socialware.PublicView

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :default, "pv-#{System.unique_integer([:positive])}")
  end

  # Spawn a bare Session Kind (no orchestrator / create_session) in workspace
  # `system`, then point its durable working copy at `template_uri` via the
  # system-internal write path — the minimal live session the resolver reads.
  defp session_for_template(template_uri) do
    uri = Ezagent.URI.session(:system, :default, "pv-#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{uri: uri, behaviors: Session.socialware_behaviors()})

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    {:ok, _} = ConfigActions.system_set_working_copy(uri, %{session_template_uri: template_uri})
    uri
  end

  describe "public_view?/1 — fail-closed default (GREEN)" do
    test "a session with no public-view Template is NOT publicly viewable" do
      refute PublicView.public_view?(session_uri())
    end

    test "a non-session URI is NOT publicly viewable" do
      refute PublicView.public_view?(Ezagent.URI.entity(:team_alpha, :user, "alice"))
      refute PublicView.public_view?(nil)
    end
  end

  describe "public_view?/1 — Template-flag resolution" do
    setup do
      # spawned Session Kinds run in their own processes — share the sandbox.
      Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
      :ok
    end

    test "true iff the session's materializing Template declares public_view: true" do
      u = System.unique_integer([:positive])

      {:ok, pubview_uri} =
        SessionTemplate.persist_version_as_system(
          %{name: "pv-tmpl-#{u}", public_view: true},
          "system"
        )

      {:ok, plain_uri} =
        SessionTemplate.persist_version_as_system(%{name: "plain-tmpl-#{u}"}, "system")

      # P materialized from a public_view: true Template → viewable
      assert PublicView.public_view?(session_for_template(pubview_uri))

      # Q materialized from a Template WITHOUT the flag → fail-closed private
      refute PublicView.public_view?(session_for_template(plain_uri))
    end

    test "fail-closed: a NON-boolean flag value (string \"true\") does NOT open the session" do
      u = System.unique_integer([:positive])

      # only an explicit boolean `true` opens; a string "true" (JSON/schema drift)
      # must stay private
      {:ok, str_uri} =
        SessionTemplate.persist_version_as_system(
          %{name: "str-tmpl-#{u}", public_view: "true"},
          "system"
        )

      refute PublicView.public_view?(session_for_template(str_uri))
    end

    test "fail-closed: a working-copy pointing at a DIFFERENT-workspace public template" do
      u = System.unique_integer([:positive])

      # a public_view:true template in workspace team-alpha; a system-workspace
      # session must NOT become public by pointing at it (cross-workspace pointer)
      {:ok, foreign_uri} =
        SessionTemplate.persist_version_as_system(
          %{name: "foreign-tmpl-#{u}", public_view: true},
          "team-alpha"
        )

      refute PublicView.public_view?(session_for_template(foreign_uri))
    end
  end
end

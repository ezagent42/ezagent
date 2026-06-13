defmodule Ezagent.Socialware.PublicViewTest do
  @moduledoc """
  Issue #51 — `public_view` is a SessionTemplate-level config (spec §3.5, OQ-6).

  The fail-closed default (`public_view?/1` is `false` for an un-flagged session) is
  tested GREEN. The Template-resolution + `:public_view` content-key plumbing is the
  TDD definition of the not-yet-built reader — tagged `:pending_impl` / `:skip`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.PublicView

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :default, "pv-#{System.unique_integer([:positive])}")
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

  describe "public_view?/1 — Template-flag resolution (PENDING)" do
    @tag :pending_impl
    @tag :skip
    test "true iff the session's materializing Template declares public_view: true" do
      # DESIRED behavior once :public_view is a SessionTemplate content key and the
      # session→Template resolver lands:
      #
      #   * materialize session P from a Template with content %{public_view: true}
      #     → PublicView.public_view?(P) == true;
      #   * materialize session Q from a Template WITHOUT the flag
      #     → PublicView.public_view?(Q) == false;
      #   * the anon-access entry mints an anon-User ONLY for P, and bounces Q to
      #     /login with no anon-User created.
      flunk("pending: SessionTemplate :public_view content key + session→Template resolver")
    end
  end
end

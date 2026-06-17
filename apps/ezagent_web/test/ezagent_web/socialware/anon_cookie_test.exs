defmodule EzagentWeb.Socialware.AnonCookieTest do
  @moduledoc """
  Issue #51 §6 — the signed `socialware_anon` cookie scheme.

  Security properties proven here:

    * a cookie minted for an anon-User on session A round-trips back to the EXACT
      anon `entity://` URI (reconstructed from `{external_user_name, session_uri}`);
    * a cookie bound to session A FAILS verify against session B (per-session bind);
    * a TAMPERED / forged / non-string value NEVER resolves to an identity
      (fail-closed → caller mints fresh);
    * a non-anon principal cannot be signed into a cookie.
  """
  use ExUnit.Case, async: true

  alias EzagentWeb.Socialware.AnonCookie
  alias Ezagent.Socialware.AnonUser

  setup do
    # AnonUser.mint/1 needs a workspace-bound session URI; the cookie scheme itself
    # is pure (signs/verifies), so we mint against an in-memory session URI without a
    # live Kind. The workspace is derived from the session URI.
    session = Ezagent.URI.new!("session://team-alpha/default/anon-cookie-#{u()}")
    other = Ezagent.URI.new!("session://team-alpha/default/anon-cookie-#{u()}")
    %{session: session, other: other}
  end

  defp u, do: System.unique_integer([:positive])

  # A deterministic anon-User URI in the session's workspace (no DB row needed —
  # the cookie scheme is pure).
  defp anon_for(session) do
    {:ok, ws} = Ezagent.URI.workspace_name(session)
    Ezagent.URI.entity(ws, :user, "#{AnonUser.prefix()}#{u()}")
  end

  describe "round-trip" do
    test "a signed cookie verifies back to the exact anon URI for THIS session", %{
      session: session
    } do
      anon = anon_for(session)
      assert {:ok, value} = AnonCookie.sign(anon, session)
      assert {:ok, recovered} = AnonCookie.verify(value, session)
      assert URI.to_string(recovered) == URI.to_string(anon)
      assert AnonUser.anon_uri?(recovered)
    end
  end

  describe "fail-closed" do
    test "a cookie bound to session A fails verify against session B", %{
      session: session,
      other: other
    } do
      anon = anon_for(session)
      {:ok, value} = AnonCookie.sign(anon, session)
      assert :error = AnonCookie.verify(value, other)
    end

    test "a tampered value never resolves to an identity", %{session: session} do
      anon = anon_for(session)
      {:ok, value} = AnonCookie.sign(anon, session)
      tampered = value <> "x"
      assert :error = AnonCookie.verify(tampered, session)
    end

    test "a value signed with a foreign key never resolves", %{session: session} do
      forged =
        Phoenix.Token.sign("a-different-secret-key-base-not-the-endpoints-aaaaaaaa", "wrong salt", %{
          "external_user_name" => "#{AnonUser.prefix()}forged",
          "session_uri" => URI.to_string(session)
        })

      assert :error = AnonCookie.verify(forged, session)
    end

    test "a non-binary / nil value is rejected", %{session: session} do
      assert :error = AnonCookie.verify(nil, session)
      assert :error = AnonCookie.verify(123, session)
      assert :error = AnonCookie.verify(%{}, session)
    end

    test "signing a non-anon principal fails closed", %{session: session} do
      real = Ezagent.URI.entity("team-alpha", :user, "real-human-#{u()}")
      assert {:error, _} = AnonCookie.sign(real, session)
    end

    test "signing against a non-session URI fails closed" do
      anon = Ezagent.URI.entity("team-alpha", :user, "#{AnonUser.prefix()}x")
      not_a_session = Ezagent.URI.entity("team-alpha", :user, "bob")
      assert {:error, _} = AnonCookie.sign(anon, not_a_session)
    end
  end
end

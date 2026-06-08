defmodule EzagentPluginLiveview.Admin.SessionContextTest do
  use ExUnit.Case, async: true

  alias EzagentPluginLiveview.Admin.SessionContext
  alias Ezagent.URI, as: EzURI
  alias Ezagent.Uploads.DownloadToken

  describe "default_main_session_uri/1" do
    test "derives the canonical main session from the current workspace" do
      assert SessionContext.default_main_session_uri(URI.new!("workspace://team-alpha")) ==
               URI.new!("session://team-alpha/default/main")
    end

    test "falls back to the system main session when no workspace is assigned" do
      assert SessionContext.default_main_session_uri(nil) ==
               URI.new!("session://system/default/main")
    end
  end

  describe "parse_mentions/2" do
    test "keeps existing bare-name mention behavior in the extracted module" do
      members = [
        %{
          "uri" => "entity://team-alpha/agent/cc_e2e_final",
          "display_name" => "Claude"
        }
      ]

      assert [uri] = SessionContext.parse_mentions("@cc_e2e_final", members)
      assert URI.to_string(uri) == "entity://team-alpha/agent/cc_e2e_final"
    end
  end

  describe "messages_to_rows/1 — upload attachment download links (Resource-unification P2)" do
    # messages_to_rows/1 resolves sender display names via EntityPresenter, which
    # reads the DB — check out a sandbox connection for this process. The mint
    # path under test is pure (token over the upload URI), exercised through the
    # real public render surface rather than the private helper.
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    end

    # A realistic stored name: a 36-char UUID prefix + "-" + the client filename
    # (matches the `consume_attachments/2` naming in Admin.Compose).
    @stored_name "11111111-2222-3333-4444-555555555555-report.pdf"
    @upload_uri EzURI.resource("team-alpha", "uploads", @stored_name)

    defp message_with_upload do
      Ezagent.Message.new(
        EzURI.new!("entity://team-alpha/user/alice"),
        %{text: "see attached", attachments: [@upload_uri]}
      )
    end

    test "renders the SOLE token route — NO legacy /files link is ever emitted" do
      [row] = SessionContext.messages_to_rows([message_with_upload()])
      [{_display, href}] = row.attachments

      assert String.starts_with?(href, "/uploads/download?token=")
      refute String.contains?(href, "/files/")
    end

    test "the minted link carries a token that verifies back to the EXACT upload URI" do
      [row] = SessionContext.messages_to_rows([message_with_upload()])
      [{_display, href}] = row.attachments

      "/uploads/download?token=" <> token = href

      assert {:ok, verified} = DownloadToken.verify(token)
      assert EzURI.stable_key(verified) == EzURI.stable_key(@upload_uri)
    end

    test "the display name strips the stored <uuid>- prefix" do
      [row] = SessionContext.messages_to_rows([message_with_upload()])
      [{display, _href}] = row.attachments

      assert display == "report.pdf"
    end

    test "a token bound to one upload cannot be replayed against another file (replay guard)" do
      [row] = SessionContext.messages_to_rows([message_with_upload()])
      [{_display, "/uploads/download?token=" <> token}] = row.attachments

      {:ok, verified} = DownloadToken.verify(token)

      refute EzURI.stable_key(verified) ==
               EzURI.stable_key(EzURI.resource("team-alpha", "uploads", "uuid-other.pdf"))

      refute EzURI.stable_key(verified) ==
               EzURI.stable_key(EzURI.resource("victim", "uploads", @stored_name))
    end
  end
end

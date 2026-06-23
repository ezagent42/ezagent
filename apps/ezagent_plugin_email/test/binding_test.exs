defmodule Ezagent.Email.BindingTest do
  @moduledoc """
  #88 PR-1 (SPEC §4.2 / HIGH 3 / HIGH 5) — email Binding publish, the
  :verified gate, recoverable transient failure, and durable threading.
  """
  use EzagentCore.DataCase, async: false
  import Swoosh.TestAssertions

  alias Ezagent.Email.{Binding, ThreadState}
  alias Ezagent.ExternalMirror.BindingRow

  @target "human@example.com"
  @ws "workspace://system"

  # Build a verified binding state + the parent binding row so the thread
  # FK + workspace derivation hold. Returns {state, session_uri}.
  defp verified_binding! do
    session_uri =
      Ezagent.URI.new!("session://system/default/bind-#{System.unique_integer([:positive])}")

    {:ok, _} =
      BindingRow.insert(%{
        id: BindingRow.row_id(session_uri, "email", @target),
        session_uri: URI.to_string(session_uri),
        adapter_id: "email",
        target_id: @target,
        opts_json: "{}",
        bound_by: "entity://system/user/admin",
        bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        workspace_uri: @ws
      })

    state = %{
      target_id: @target,
      opts: %{},
      verification_status: :verified,
      publish_count: 0,
      error_count: 0
    }

    {state, session_uri}
  end

  defp payload(session_uri, opts \\ []) do
    %{
      subject: Keyword.get(opts, :subject, "[s] hi"),
      text: Keyword.get(opts, :text, "body text"),
      html: nil,
      session_uri: session_uri
    }
  end

  describe "init/1" do
    test "valid address → :pending_verification state (NEVER reads opts status)" do
      assert {:ok, state} =
               Binding.init({@target, Ezagent.Email.Adapter, %{verification_status: :verified}})

      # Forgery guard: an opts-supplied :verified must NOT leak in.
      assert state.verification_status == :pending_verification
      assert state.target_id == @target
    end

    test "malformed target_id → {:error, {:invalid_target_id, _}}" do
      assert {:error, {:invalid_target_id, _}} =
               Binding.init({"not-an-address", Ezagent.Email.Adapter, %{}})

      assert {:error, {:invalid_target_id, _}} =
               Binding.init({123, Ezagent.Email.Adapter, %{}})
    end
  end

  describe "publish/2 verification gate" do
    test "refuses to send when not verified (recoverable)" do
      session_uri = Ezagent.URI.new!("session://system/default/unverified")

      state = %{
        target_id: @target,
        opts: %{},
        verification_status: :pending_verification,
        publish_count: 0,
        error_count: 0
      }

      assert {:error, :not_verified, ^state} = Binding.publish(payload(session_uri), state)
    end
  end

  describe "publish/2 outbound + threading" do
    test "verified → sends one email with a Message-ID; advances thread state" do
      {state, session_uri} = verified_binding!()

      assert {:ok, new_state} = Binding.publish(payload(session_uri, text: "hello"), state)
      assert new_state.publish_count == 1

      assert_email_sent(fn email ->
        assert {_, @target} = hd(email.to)
        assert email.text_body == "hello"
        assert is_binary(email.headers["Message-ID"])
        # RFC 5322: the ROOT message has no prior messages → no References,
        # no In-Reply-To.
        not Map.has_key?(email.headers, "References") and
          not Map.has_key?(email.headers, "In-Reply-To")
      end)

      row_id = BindingRow.row_id(session_uri, "email", @target)
      ts = ThreadState.load(row_id)
      assert ts.root_message_id == ts.last_message_id
      # Persisted chain = this message's id (grows on the NEXT send).
      assert ts.references_chain == ts.last_message_id
      assert ts.workspace_uri == @ws
    end

    test "second send sets In-Reply-To to the prior id and grows References" do
      {state, session_uri} = verified_binding!()

      {:ok, _} = Binding.publish(payload(session_uri, text: "first"), state)
      row_id = BindingRow.row_id(session_uri, "email", @target)
      first = ThreadState.load(row_id)

      {:ok, _} = Binding.publish(payload(session_uri, text: "second"), state)

      assert_email_sent(fn email ->
        # Most recent email: In-Reply-To = first message id; References lists
        # the PRIOR message (the first), RFC 5322 — and must NOT contain this
        # message's own Message-ID.
        if email.text_body == "second" do
          assert email.headers["In-Reply-To"] == first.last_message_id
          assert email.headers["References"] =~ first.last_message_id
          refute email.headers["References"] =~ email.headers["Message-ID"]
        end

        true
      end)

      second = ThreadState.load(row_id)
      assert second.root_message_id == first.root_message_id
      assert second.last_message_id != first.last_message_id
      # Persisted chain now lists BOTH ids (ready for the 3rd send's References).
      assert second.references_chain =~ first.last_message_id
      assert second.references_chain =~ second.last_message_id
    end

    test "threading survives a simulated Worker restart (reloads from ThreadState)" do
      {state, session_uri} = verified_binding!()

      {:ok, _} = Binding.publish(payload(session_uri, text: "first"), state)
      row_id = BindingRow.row_id(session_uri, "email", @target)
      first = ThreadState.load(row_id)

      # Fresh init (Worker restart) — state has no in-memory thread carry.
      {:ok, fresh} = Binding.init({@target, Ezagent.Email.Adapter, %{}})
      fresh = %{fresh | verification_status: :verified}

      {:ok, _} = Binding.publish(payload(session_uri, text: "after-restart"), fresh)

      assert_email_sent(fn email ->
        if email.text_body == "after-restart" do
          assert email.headers["In-Reply-To"] == first.last_message_id
        end

        true
      end)
    end

    test "header fields contain no CR/LF even with hostile subject" do
      {state, session_uri} = verified_binding!()
      hostile_subject = "x\r\nBcc: evil@x"

      assert {:ok, _} = Binding.publish(payload(session_uri, subject: hostile_subject), state)

      assert_email_sent(fn email ->
        refute email.subject =~ "\r"
        refute email.subject =~ "\n"
        refute email.headers["Message-ID"] =~ "\r"
        true
      end)
    end
  end

  describe "publish/2 recoverable transient failure (HIGH 3)" do
    test "mail-not-configured → {:error, reason, new_state}, no crash" do
      {state, session_uri} = verified_binding!()

      # Force the SMTP adapter (no smtp_config in test) so send/4 returns
      # {:error, :mail_not_configured} rather than the Test-adapter success.
      prev = Application.get_env(:ezagent_plugin_email, Ezagent.Email.Mailer)

      Application.put_env(:ezagent_plugin_email, Ezagent.Email.Mailer,
        adapter: Swoosh.Adapters.SMTP
      )

      on_exit(fn -> Application.put_env(:ezagent_plugin_email, Ezagent.Email.Mailer, prev) end)

      assert {:error, :mail_not_configured, new_state} =
               Binding.publish(payload(session_uri), state)

      assert new_state.error_count == 1
    end
  end
end

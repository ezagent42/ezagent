defmodule Ezagent.Email.Inbound.GuardTest do
  @moduledoc """
  #88 PR-2 (SPEC §4.5 / §7 / BLOCKER 2 / MED 8) — pure inbound guards.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Email.Inbound.Guard

  @target "human@example.com"

  defp rec(overrides) do
    Map.merge(
      %{
        "from" => @target,
        "messageId" => "<m1@x>",
        "returnPath" => "human@example.com",
        "autoSubmitted" => "no",
        "precedence" => "",
        "authResults" => "spf=pass dkim=pass dmarc=pass"
      },
      overrides
    )
  end

  describe "accept_for_injection?/1 (loop/bounce guard)" do
    test "accepts a normal human reply" do
      assert Guard.accept_for_injection?(rec(%{})) == :ok
    end

    test "rejects an empty envelope-from (bounce/NDR marker)" do
      assert {:reject, :bounce} = Guard.accept_for_injection?(rec(%{"returnPath" => "<>"}))
      assert {:reject, :bounce} = Guard.accept_for_injection?(rec(%{"returnPath" => ""}))
    end

    test "rejects Auto-Submitted other than no" do
      assert {:reject, :auto_submitted} =
               Guard.accept_for_injection?(rec(%{"autoSubmitted" => "auto-replied"}))

      assert {:reject, :auto_submitted} =
               Guard.accept_for_injection?(rec(%{"autoSubmitted" => "auto-generated"}))
    end

    test "rejects Precedence bulk/auto_reply/list" do
      for p <- ~w(bulk auto_reply list) do
        assert {:reject, :bulk_precedence} =
                 Guard.accept_for_injection?(rec(%{"precedence" => p}))
      end
    end

    test "rejects a record with no Message-ID" do
      assert {:reject, :no_message_id} =
               Guard.accept_for_injection?(rec(%{"messageId" => ""}))

      assert {:reject, :no_message_id} =
               Guard.accept_for_injection?(rec(%{"messageId" => nil}))
    end
  end

  describe "authenticated?/2 (DMARC + From-match)" do
    test "accepts DMARC pass + From == target" do
      assert Guard.authenticated?(rec(%{}), @target) == :ok
    end

    test "accepts a Display Name <addr> From form" do
      assert Guard.authenticated?(rec(%{"from" => "Human <human@example.com>"}), @target) == :ok
    end

    test "rejects a From mismatch" do
      assert {:reject, :from_mismatch} =
               Guard.authenticated?(rec(%{"from" => "other@example.com"}), @target)
    end

    test "rejects a forged From (right address, DMARC fails)" do
      assert {:reject, :auth_failed} =
               Guard.authenticated?(
                 rec(%{"authResults" => "spf=fail dkim=fail dmarc=fail"}),
                 @target
               )
    end

    test "rejects a missing auth verdict (no degrade-to-allow)" do
      assert {:reject, :auth_failed} =
               Guard.authenticated?(rec(%{"authResults" => ""}), @target)
    end

    test "rejects DMARC pass but no SPF/DKIM pass" do
      assert {:reject, :auth_failed} =
               Guard.authenticated?(
                 rec(%{"authResults" => "spf=fail dkim=fail dmarc=pass"}),
                 @target
               )
    end
  end
end

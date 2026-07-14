defmodule Ezagent.Identity.CapSigningBackfillTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.Identity.CapSigningBackfill

  @holder Ezagent.URI.new!("entity://team-alpha/user/alice")
  @issuer Ezagent.URI.new!("entity://team-alpha/user/issuer")
  @other_issuer Ezagent.URI.new!("entity://team-alpha/user/other-issuer")
  @other_holder Ezagent.URI.new!("entity://team-alpha/user/bob")
  @workspace Ezagent.URI.new!("workspace://team-alpha")
  @granted_at_a ~U[2026-07-14 12:00:00Z]
  @granted_at_b ~U[2026-07-14 13:00:00Z]

  describe "dry_run/1" do
    test "re-authorizes only the matching EventLog grant and reports without retaining a replacement" do
      source_cap =
        %{legacy_cap() | signature: <<1, 2, 3>>, key_id: "v1|old", grantee_uri: @holder}

      issue = fn {:held_by, @issuer}, @holder, proposal ->
        send(self(), {:reissued, proposal})
        {:ok, %{proposal | signature: <<4, 5, 6>>, key_id: "v1|new", grantee_uri: @holder}}
      end

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [grant_event(source_cap)] end,
                 issue: issue
               )

      assert_receive {:reissued,
                      %Capability{
                        signature: nil,
                        key_id: nil,
                        grantee_uri: nil,
                        granted_by: @issuer
                      }}

      assert %{scanned: 1, would_sign: 1, quarantined: 0, skipped: 0} = report

      assert [
               %{
                 status: :would_sign,
                 holder: @holder,
                 event_id: 41,
                 identity_key: identity_key
               }
             ] = report.entries

      assert identity_key == Capability.identity_key(legacy_cap())
      refute Map.has_key?(hd(report.entries), :replacement)
    end

    test "quarantines a candidate that has no authoritative grant event" do
      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [] end,
                 issue: fn _, _, _ -> flunk("issue must not run without an event") end
               )

      assert [%{status: :quarantined, reason: :missing_authoritative_grant_event}] =
               report.entries
    end

    test "quarantines a candidate when current authorization rejects EventLog replay" do
      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [grant_event(legacy_cap())] end,
                 issue: fn {:held_by, @issuer}, @holder, _proposal -> {:error, :unauthorized} end
               )

      assert [%{status: :quarantined, reason: {:reauthorization_failed, :unauthorized}}] =
               report.entries
    end

    test "skips declarative sentinels without reading EventLog" do
      sentinel = Capability.cap(:session, Ezagent.ActionSet.Session, :send)

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [%{home: :users, holder: @holder, cap: sentinel}],
                 event_streamer: fn _ -> flunk("sentinels must not query EventLog") end,
                 issue: fn _, _, _ -> flunk("sentinels must not issue") end
               )

      assert [%{status: :skipped, reason: :sentinel}] = report.entries
    end

    test "deduplicates the same holder and identity from users and snapshot homes before replay" do
      issue = fn {:held_by, @issuer}, @holder, _proposal ->
        send(self(), :issue_called)
        {:ok, legacy_cap()}
      end

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users), candidate(:snapshot)],
                 event_streamer: fn @holder -> [grant_event(legacy_cap())] end,
                 issue: issue
               )

      assert_receive :issue_called
      refute_receive :issue_called
      assert %{scanned: 1, would_sign: 1} = report
    end

    test "quarantines a cap_granted event with a malformed payload" do
      malformed_event = %{
        event_id: 41,
        event_name: "cap_granted",
        payload: %{"target_uri" => Ezagent.URI.stable_key(@holder), "cap" => %{"not" => "a cap"}}
      }

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [malformed_event] end,
                 issue: fn _, _, _ -> flunk("malformed event must not issue") end
               )

      assert [%{status: :quarantined, reason: :malformed_authoritative_grant_event}] =
               report.entries
    end

    test "quarantines malformed EventLog signing fields without rescuing replay failures" do
      malformed_event =
        legacy_cap()
        |> grant_event()
        |> update_in([:payload, "cap", "signature"], fn _ -> :not_a_binary end)

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [malformed_event] end,
                 issue: fn _, _, _ -> flunk("malformed event must not issue") end
               )

      assert [%{status: :quarantined, reason: :malformed_authoritative_grant_event}] =
               report.entries
    end

    test "does not replay an EventLog row that lacks the cap_granted name" do
      malformed_event = legacy_cap() |> grant_event() |> Map.delete(:event_name)

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [malformed_event] end,
                 issue: fn _, _, _ -> flunk("unnamed event must not issue") end
               )

      assert [%{status: :quarantined, reason: :malformed_authoritative_grant_event}] =
               report.entries
    end

    test "binds the current cap to the later exact grant after an earlier same-axis lifecycle" do
      cap_a = legacy_cap(granted_at: @granted_at_a)
      cap_b = legacy_cap(granted_at: @granted_at_b)

      issue = fn {:held_by, @issuer}, @holder, proposal ->
        send(self(), {:reissued, proposal.granted_at})
        {:ok, proposal}
      end

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users, cap_b)],
                 event_streamer: fn @holder ->
                   [grant_event(cap_a, 1), revoke_event(cap_a, 2), grant_event(cap_b, 3)]
                 end,
                 issue: issue
               )

      assert_receive {:reissued, @granted_at_b}
      assert [%{status: :would_sign, event_id: 3}] = report.entries
    end

    test "quarantines a stale candidate whose bound grant was later revoked" do
      cap_a = legacy_cap(granted_at: @granted_at_a)
      cap_b = legacy_cap(granted_at: @granted_at_b)

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users, cap_a)],
                 event_streamer: fn @holder ->
                   [grant_event(cap_a, 1), revoke_event(cap_a, 2), grant_event(cap_b, 3)]
                 end,
                 issue: fn _, _, _ -> flunk("revoked source must not issue") end
               )

      assert [%{status: :quarantined, reason: :authoritative_grant_revoked}] = report.entries
    end

    test "quarantines a stale candidate superseded by a later same-identity grant" do
      cap_a = legacy_cap(granted_at: @granted_at_a)
      cap_b = legacy_cap(granted_at: @granted_at_b)

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users, cap_a)],
                 event_streamer: fn @holder -> [grant_event(cap_a, 1), grant_event(cap_b, 2)] end,
                 issue: fn _, _, _ -> flunk("superseded source must not issue") end
               )

      assert [%{status: :quarantined, reason: :authoritative_grant_superseded}] = report.entries
    end

    test "keeps divergent durable-home sources distinct so only the current grant can reauthorize" do
      cap_a = legacy_cap(granted_at: @granted_at_a)
      cap_b = legacy_cap(granted_at: @granted_at_b)

      issue = fn {:held_by, @issuer}, @holder, proposal ->
        send(self(), {:reissued, proposal.granted_at})
        {:ok, proposal}
      end

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users, cap_a), candidate(:snapshot, cap_b)],
                 event_streamer: fn @holder -> [grant_event(cap_a, 1), grant_event(cap_b, 2)] end,
                 issue: issue
               )

      assert_receive {:reissued, @granted_at_b}
      refute_receive {:reissued, @granted_at_a}

      assert %{scanned: 2, would_sign: 1, quarantined: 1} = report

      assert Enum.any?(report.entries, fn entry ->
               entry.status == :quarantined and entry.reason == :authoritative_grant_superseded
             end)

      assert Enum.any?(report.entries, &(&1.status == :would_sign and &1.event_id == 2))
    end

    test "does not bind a same-axis grant with different provenance" do
      event_cap = legacy_cap(granted_by: @other_issuer)

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [grant_event(event_cap)] end,
                 issue: fn _, _, _ -> flunk("provenance mismatch must not issue") end
               )

      assert [%{status: :quarantined, reason: :missing_authoritative_grant_event}] =
               report.entries
    end

    test "does not bind an EventLog grant whose grantee belongs to another holder" do
      event_cap = %{legacy_cap() | grantee_uri: @other_holder}

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [grant_event(event_cap)] end,
                 issue: fn _, _, _ -> flunk("grantee mismatch must not issue") end
               )

      assert [%{status: :quarantined, reason: :missing_authoritative_grant_event}] =
               report.entries
    end

    test "does not treat another holder's grantee-bound revocation as relevant" do
      cross_holder_revoke = %{legacy_cap() | grantee_uri: @other_holder}

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder ->
                   [grant_event(legacy_cap(), 1), revoke_event(cross_holder_revoke, 2)]
                 end,
                 issue: fn {:held_by, @issuer}, @holder, proposal -> {:ok, proposal} end
               )

      assert [%{status: :would_sign, event_id: 1}] = report.entries
    end

    test "quarantines an unknown event atom instead of tolerantly widening it" do
      malformed_event =
        legacy_cap()
        |> grant_event()
        |> put_in([:payload, "cap", "behavior"], "Elixir.Ezagent.UnknownCapabilityBehavior")

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [malformed_event] end,
                 issue: fn _, _, _ -> flunk("unknown event atom must not issue") end
               )

      assert [%{status: :quarantined, reason: :malformed_authoritative_grant_event}] =
               report.entries
    end

    test "quarantines an invalid event timestamp instead of accepting a defaulted time" do
      malformed_event =
        legacy_cap()
        |> grant_event()
        |> put_in([:payload, "cap", "granted_at"], "not-a-timestamp")

      assert {:ok, report} =
               CapSigningBackfill.dry_run(
                 candidates: [candidate(:users)],
                 event_streamer: fn @holder -> [malformed_event] end,
                 issue: fn _, _, _ -> flunk("invalid event timestamp must not issue") end
               )

      assert [%{status: :quarantined, reason: :malformed_authoritative_grant_event}] =
               report.entries
    end
  end

  describe "mix ezagent.cap.backfill" do
    test "refuses invocation without --dry-run before the application starts" do
      assert_raise Mix.Error, ~r/only supports --dry-run/, fn ->
        Mix.Tasks.Ezagent.Cap.Backfill.run([])
      end
    end
  end

  test "dry-run planner has no durable write surface" do
    source =
      File.read!(Path.expand("../../../lib/ezagent/identity/cap_signing_backfill.ex", __DIR__))

    refute source =~ "Repo."
    refute source =~ "Ecto.Changeset"
    refute source =~ "KindSnapshot.upsert"
  end

  defp candidate(home, cap \\ legacy_cap()), do: %{home: home, holder: @holder, cap: cap}

  defp grant_event(cap, event_id \\ 41) do
    %{
      event_id: event_id,
      event_name: "cap_granted",
      payload: %{
        "target_uri" => Ezagent.URI.stable_key(@holder),
        "cap" => Capability.to_map(cap)
      }
    }
  end

  defp revoke_event(cap, event_id) do
    %{
      event_id: event_id,
      event_name: "cap_revoked",
      payload: %{
        "target_uri" => Ezagent.URI.stable_key(@holder),
        "cap" => Capability.to_map(cap)
      }
    }
  end

  defp legacy_cap(opts \\ []) do
    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: Ezagent.URI.new!("session://team-alpha/default/chat"),
      workspace_uri: @workspace,
      granted_by: Keyword.get(opts, :granted_by, @issuer),
      granted_at: Keyword.get(opts, :granted_at, @granted_at_a)
    }
  end
end

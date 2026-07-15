defmodule Ezagent.CapSigningNotailInvestigationTest do
  @moduledoc """
  Opt-in drain gate for a throwaway restore of the real canary database.

  Run only against the isolated clone described in the handoff with
  `CAP_SIGNING_INVESTIGATION=1`. The test never assumes fixture counts: it runs
  the production cold sweeper until the four-source strict audit is clean or
  reports the remaining unsigned/quarantine worklist for lead disposition.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Identity.{CapSigningAudit, CapSigningSweeper}

  @moduletag :cap_signing_investigation
  @moduletag skip:
               if(System.get_env("CAP_SIGNING_INVESTIGATION") == "1",
                 do: false,
                 else: "requires the isolated canary database clone"
               )

  test "the production sweeper drains the restored four-source inventory to strict zero" do
    started = start_reconciliation_apps!()
    on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)

    before = CapSigningAudit.scan()
    {last_sweep, after_drain} = drain_until_settled(100)

    IO.inspect(before, label: "cap signing audit before canary drain", pretty: true)
    IO.inspect(last_sweep, label: "last cap signing sweep", pretty: true)
    IO.inspect(after_drain, label: "cap signing audit after canary drain", pretty: true)

    assert last_sweep.enqueue_errors == [],
           "cold sweep still has enqueue failures: #{inspect(last_sweep.enqueue_errors)}"

    assert after_drain.totals.unsigned_authorizer == 0,
           "unsigned canary tail remains: #{inspect(after_drain)}"

    assert after_drain.totals.open_quarantined == 0,
           "OPEN quarantine requires lead disposition: #{inspect(after_drain)}"
  end

  defp start_reconciliation_apps! do
    [:ezagent_web, :ezagent_plugin_cc, :ezagent_plugin_curl_agent, :ezagent_plugin_py]
    |> Enum.flat_map(fn app ->
      {:ok, started} = Application.ensure_all_started(app)
      started
    end)
    |> Enum.uniq()
  end

  defp drain_until_settled(0) do
    {%{enqueue_errors: [:retry_budget_exhausted]}, CapSigningAudit.scan()}
  end

  defp drain_until_settled(attempts) do
    result = CapSigningSweeper.sweep()
    report = CapSigningAudit.scan()

    if CapSigningAudit.clean?(report) and result.enqueue_errors == [] do
      {result, report}
    else
      Process.sleep(100)
      drain_until_settled(attempts - 1)
    end
  end
end

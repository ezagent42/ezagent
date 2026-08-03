defmodule Ezagent.Session.SocialwareInstallSweeperTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Session.{
    SocialwareInstallObligation,
    SocialwareInstallObligations,
    SocialwareInstallSweeper
  }

  test "a returned error remains durable and a later success resolves the same obligation" do
    obligation = pending_obligation("returned-error")
    attempt_key = {__MODULE__, make_ref()}
    Process.put(attempt_key, 0)

    install = fn _session_uri, _authorization ->
      attempt = Process.get(attempt_key) + 1
      Process.put(attempt_key, attempt)

      if attempt == 1,
        do: {:error, :database_busy},
        else: {:ok, %{satisfied: ["front-desk", "llm"], skipped: []}}
    end

    assert {:error, :database_busy} =
             SocialwareInstallSweeper.retry(obligation.id, install_fun: install)

    retryable = SocialwareInstallObligations.get!(obligation.id)
    assert retryable.status == :pending
    assert retryable.last_error == ":database_busy"

    {:ok, _due} =
      retryable
      |> SocialwareInstallObligation.transition_changeset(%{
        next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> EzagentCore.Repo.update()

    assert {:ok, :resolved} =
             SocialwareInstallSweeper.retry(obligation.id, install_fun: install)

    resolved = SocialwareInstallObligations.get!(obligation.id)
    assert resolved.status == :resolved
    assert resolved.attempts == 2
    assert Process.get(attempt_key) == 2
    Process.delete(attempt_key)
  end

  test "an installer crash is captured as retryable state" do
    obligation = pending_obligation("crash")

    install = fn _session_uri, _authorization ->
      raise "synthetic installer crash"
    end

    assert {:error, {:rescue, %RuntimeError{message: "synthetic installer crash"}}} =
             SocialwareInstallSweeper.retry(obligation.id, install_fun: install)

    retryable = SocialwareInstallObligations.get!(obligation.id)
    assert retryable.status == :pending
    assert retryable.last_error =~ "synthetic installer crash"
    assert is_nil(retryable.claim_token)
  end

  test "a long-running installer renews its lease and cannot be reclaimed concurrently" do
    obligation = pending_obligation("lease-heartbeat")
    parent = self()

    install = fn _session_uri, _authorization ->
      send(parent, :installer_started)

      receive do
        :finish_install -> {:ok, %{satisfied: ["front-desk"], skipped: []}}
      end
    end

    task =
      Task.async(fn ->
        SocialwareInstallSweeper.retry(obligation.id,
          install_fun: install,
          lease_seconds: 1
        )
      end)

    assert :ok = Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), task.pid)
    assert_receive :installer_started, 1_000

    claimed = SocialwareInstallObligations.get!(obligation.id)
    assert DateTime.diff(claimed.next_attempt_at, DateTime.utc_now(), :second) <= 1

    Process.sleep(1_200)
    assert {:error, :already_claimed} = SocialwareInstallObligations.claim(obligation.id)

    send(task.pid, :finish_install)
    assert {:ok, :resolved} = Task.await(task)
  end

  test "the supervised periodic sweeper resumes durable work present at startup" do
    parent = self()
    first = pending_obligation("periodic-before-restart")

    install = fn session_uri, _authorization ->
      send(parent, {:installed, session_uri})
      {:ok, %{satisfied: ["front-desk"], skipped: []}}
    end

    pid =
      start_supervised!(
        {SocialwareInstallSweeper, interval: 20, retry_opts: [install_fun: install]}
      )

    assert_receive {:installed, first_session_uri}, 1_000
    assert URI.to_string(first_session_uri) == first.session_uri
    assert_eventually_resolved(first.id)
    assert Process.alive?(pid)
  end

  defp pending_obligation(name) do
    suffix = System.unique_integer([:positive])

    {:ok, obligation} =
      SocialwareInstallObligations.ensure_pending(
        Ezagent.URI.new!("session://team-alpha/hello/#{name}-#{suffix}"),
        Ezagent.URI.new!("workspace://team-alpha"),
        Ezagent.URI.new!("entity://team-alpha/user/owner-#{suffix}")
      )

    obligation
  end

  defp assert_eventually_resolved(id, attempts \\ 50)

  defp assert_eventually_resolved(id, attempts) when attempts > 0 do
    case SocialwareInstallObligations.get!(id).status do
      :resolved ->
        :ok

      _status ->
        Process.sleep(20)
        assert_eventually_resolved(id, attempts - 1)
    end
  end

  defp assert_eventually_resolved(id, 0) do
    flunk("obligation #{id} did not resolve")
  end
end

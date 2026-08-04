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

  test "a view-cap convergence failure remains pending and resolves on retry" do
    obligation = pending_obligation("view-cap-convergence")
    attempt_key = {__MODULE__, make_ref()}
    Process.put(attempt_key, 0)

    install = fn _session_uri, _authorization ->
      attempt = Process.get(attempt_key) + 1
      Process.put(attempt_key, attempt)

      if attempt == 1 do
        {:error,
         {:member_view_cap_failed, Ezagent.URI.new!("entity://team-alpha/user/owner"),
          Ezagent.ActionSet.HelloRender, :hello_render, :grant_timeout}}
      else
        {:ok, %{satisfied: [], skipped: []}}
      end
    end

    assert {:error, {:member_view_cap_failed, _, _, :hello_render, :grant_timeout}} =
             SocialwareInstallSweeper.retry(obligation.id, install_fun: install)

    retryable = SocialwareInstallObligations.get!(obligation.id)
    assert retryable.status == :pending
    assert retryable.last_error =~ "member_view_cap_failed"

    {:ok, _due} =
      retryable
      |> SocialwareInstallObligation.transition_changeset(%{
        next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> EzagentCore.Repo.update()

    assert {:ok, :resolved} =
             SocialwareInstallSweeper.retry(obligation.id, install_fun: install)

    assert SocialwareInstallObligations.get!(obligation.id).status == :resolved
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

  test "heartbeat failures cannot kill the installer" do
    Enum.each(
      [
        returned_error: fn -> {:error, :database_unavailable} end,
        exception: fn -> raise "synthetic heartbeat exception" end,
        exit: fn -> exit(:synthetic_heartbeat_exit) end
      ],
      fn {failure_kind, fail_renewal} ->
        obligation = pending_obligation("heartbeat-#{failure_kind}")
        parent = self()

        install = fn _session_uri, _authorization ->
          send(parent, {:installer_started, failure_kind})

          receive do
            {:finish_install, ^failure_kind} ->
              {:ok, %{satisfied: ["front-desk"], skipped: []}}
          end
        end

        renew = fn _id, _claim_token, _lease_seconds ->
          send(parent, {:heartbeat_attempted, failure_kind})
          fail_renewal.()
        end

        task =
          Task.async(fn ->
            SocialwareInstallSweeper.retry(obligation.id,
              install_fun: install,
              renew_fun: renew,
              lease_seconds: 1
            )
          end)

        assert :ok = Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), task.pid)
        assert_receive {:installer_started, ^failure_kind}, 1_000
        assert_receive {:heartbeat_attempted, ^failure_kind}, 1_000
        assert Process.alive?(task.pid)

        send(task.pid, {:finish_install, failure_kind})
        assert {:ok, :resolved} = Task.await(task)
      end
    )
  end

  test "heartbeat stops renewing before retry returns" do
    obligation = pending_obligation("heartbeat-stop")
    parent = self()

    install = fn _session_uri, _authorization ->
      receive do
        :finish_install -> {:ok, %{satisfied: ["front-desk"], skipped: []}}
      end
    end

    renew = fn _id, _claim_token, _lease_seconds ->
      send(parent, :heartbeat_renewed)
      {:ok, :renewed}
    end

    task =
      Task.async(fn ->
        SocialwareInstallSweeper.retry(obligation.id,
          install_fun: install,
          renew_fun: renew,
          lease_seconds: 1
        )
      end)

    assert :ok = Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), task.pid)
    assert_receive :heartbeat_renewed, 1_000
    send(task.pid, :finish_install)
    assert {:ok, :resolved} = Task.await(task)
    refute_receive :heartbeat_renewed, 500
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

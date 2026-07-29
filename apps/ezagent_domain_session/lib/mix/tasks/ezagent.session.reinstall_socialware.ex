defmodule Mix.Tasks.Ezagent.Session.ReinstallSocialware do
  @shortdoc "Re-run a session's socialware role-slot materialization (fills skipped roles after credentials arrive)"
  @moduledoc """
  任务 B（handoff 2026-07-16 gaga-agent-runtime §4）—— 补物化的 operator 触发面。

  凭证缺失时 socialware install 会 loud-skip 角色（`Ezagent.Agent.
  CredentialPrecondition`，chain C）；skip 行是 install 时刻的 durable 快照
  （`unfilled_agent_role_slots`），补员不会自己发生。operator 配好凭证源之后
  （`mix ezagent.credential.adopt` / workspace 的
  `set_workspace_shared_credential_source` action），跑本 task 重新走同一条
  幂等 install 管道（`SessionCreator.install_session_socialware/2` —— a role
  already joined is skipped）：凭证就位的角色补物化进成员表，skip 行随
  `record_unfilled_role_slots(summary.skipped)` 全量重写自动清掉；仍然缺凭证
  的角色保持 skip（loud，不假强保证）。

  ## Usage

      mix ezagent.session.reinstall_socialware <session_uri>

  以 session OWNER 的身份重装（composition 授权检查照 owner 过——补物化语义
  就是"代 owner 重装"）。
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [session_uri_str | _] when is_binary(session_uri_str) and session_uri_str != "" ->
        session_uri = parse_session_uri!(session_uri_str)

        workspace_uri =
          case Ezagent.Capability.workspace_of(session_uri) do
            %URI{} = ws -> ws
            :any -> Mix.raise("cannot derive workspace from #{URI.to_string(session_uri)}")
          end

        # `Session.owner/1` deliberately reads only a live Kind. A Mix task
        # starts in a fresh VM, so restore the persisted Session before asking
        # it for the owner rather than treating a cold (but valid) Session as
        # missing.
        with {:ok, _pid} <- Ezagent.SpawnRegistry.ensure_live(session_uri) do
          owner =
            case Ezagent.Entity.Session.owner(session_uri) do
              {:ok, %URI{} = owner} -> owner
              other -> Mix.raise("cannot resolve session owner: #{inspect(other)}")
            end

          before =
            EzagentDomainInstanceMessage.SessionCreator.unfilled_agent_role_slots(session_uri)

          case EzagentDomainInstanceMessage.SessionCreator.install_session_socialware(
                 session_uri,
                 {workspace_uri, owner}
               ) do
            {:ok, %{satisfied: satisfied, skipped: skipped}} ->
              Mix.shell().info("reinstall of #{URI.to_string(session_uri)}:")

              Mix.shell().info(
                "  previously unfilled: #{inspect(Enum.map(before, & &1.role_name))}"
              )

              Mix.shell().info("  satisfied now:       #{inspect(satisfied)}")

              Enum.each(skipped, fn %{role_name: role, reason: reason} ->
                Mix.shell().info("  still skipped:       #{role} — #{inspect(reason)}")
              end)

              :ok

            {:error, reason} ->
              Mix.raise("reinstall failed: #{inspect(reason)}")

            {:error, reason, partial} ->
              Mix.raise("reinstall failed: #{inspect(reason)} (partial: #{inspect(partial)})")
          end
        else
          {:error, reason} ->
            Mix.raise("cannot restore session: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("""
        Missing arguments.

        Usage:
          mix ezagent.session.reinstall_socialware <session_uri>
        """)
    end
  end

  defp parse_session_uri!(str) do
    case Ezagent.URI.parse(String.trim(str)) do
      {:ok, %URI{scheme: "session"} = uri} -> uri
      {:ok, %URI{} = other} -> Mix.raise("not a session URI: #{URI.to_string(other)}")
      _ -> Mix.raise("bad session URI: #{inspect(str)}")
    end
  end
end

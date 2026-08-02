defmodule Mix.Tasks.Ezagent.Agent.GrantGitIdentity do
  @shortdoc "授权一个 agent 读取某个 User 的 SSH 私钥（SSH 凭据 1b）"

  @moduledoc """
  Grant `<agent_uri>` the `read_ssh_key` capability on `<user_uri>`.

      mix ezagent.agent.grant_git_identity entity://acme/agent/dev-1 entity://acme/user/allen

  That single capability is the **entire switch** for form B2′: holding it, the
  agent gets the User's SSH private key materialized into its own git-identity
  dir at every spawn, plus a `GIT_SSH_COMMAND` pointing at it. Not holding it,
  nothing happens at all. The capability granted is
  `Ezagent.ActionSet.UserSshIdentity`'s `:read_ssh_key` action, scoped to
  `<user_uri>` — this task never references that Behavior module directly
  (`Ezagent.Cap.issue_for_action/3` derives the required cap from the dispatch
  target instead), but that IS what gets issued.

  **This is a deliberate, per-agent, human decision.** The capability's
  `instance` field is simultaneously the authorization and the pointer to whose
  key — see `Ezagent.Identity.AgentGitIdentity`.

  ## 撤销不是即时的

  Revoking the capability takes effect at the agent's **next spawn**; the key
  file already on disk is unaffected. To cut access immediately, also remove the
  agent's git-identity dir and restart it. This is inherent to form B2′ (once a
  key reaches a filesystem the agent can read, the platform has lost control of
  it), not a defect of this task.

  ## 冲突检测 —— 防止歧义身份状态

  `Ezagent.Identity.list_caps_for/1` returns a `MapSet`, and a capability's
  identity key includes `instance` — so a `read_ssh_key` cap pointing at User A
  and one pointing at User B are two DISTINCT caps, not something the store
  rejects as a duplicate. An operator re-pointing an agent from A to B who runs
  this task against B WITHOUT first revoking A would leave the agent holding
  both — `Ezagent.Identity.AgentGitIdentity.materialize/1` already treats that
  as a configuration error on the CONSUMING side (`{:error,
  {:ambiguous_git_identity, _}}`, and it wipes the agent's git-identity dir
  rather than picking one — see that module's moduledoc). Waiting until the
  next spawn to discover the mistake is strictly worse than catching it at
  grant time, so this task checks first.

  Before issuing, `grant/2` reads the agent's currently-held `read_ssh_key`
  caps through **the exact same selector Task 3's consumer uses**
  (`Ezagent.Identity.AgentGitIdentity.dispatch_caps/1` — not a re-implemented
  filter, so the two sides cannot drift apart):

    * an existing cap pointing at the **same** `<user_uri>` is not a conflict —
      granting again is idempotent (the Identity store dedups by identity key,
      i.e. `{kind, behavior, action, instance, workspace}`; re-issuing the same
      one just replaces it with a freshly-signed artifact, the held set stays
      at exactly one)
    * an existing cap pointing at a **different** User is refused outright —
      `{:error, {:conflicting_git_identity, [URI.t()]}}`, telling the operator
      to revoke the old one first via `Ezagent.EntityCaps.revoke/2`

  **Why refuse outright instead of an `--force`-style override flag:** the
  two-cap state has no legitimate use — it is not a valid intermediate step of
  anything, it is a misconfiguration that the consuming side already refuses to
  act on (loudly, wiping the directory) the very next time the agent spawns.
  An override flag would only ever let an operator manufacture a state that
  breaks the agent's git identity on its next restart; it buys no real
  transition capability, so it is not worth the extra flag and branch. The
  operator's way out is two ordinary commands: revoke, then grant.
  """

  use Mix.Task

  @requirements ["app.config"]
  @absorb_timeout_ms 5_000

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    with {:ok, %{agent: agent, user: user}} <- plan(argv),
         {:ok, cap} <- grant(agent, user) do
      Mix.shell().info(
        "granted #{inspect(cap.action)} on #{URI.to_string(user)} to #{URI.to_string(agent)}"
      )

      Mix.shell().info("takes effect at the agent's next spawn")
    else
      {:error, {:conflicting_git_identity, existing}} ->
        existing_str = existing |> Enum.map(&URI.to_string/1) |> Enum.join(", ")

        Mix.raise(
          "ezagent.agent.grant_git_identity failed: this agent already holds a " <>
            "read_ssh_key cap pointing at a DIFFERENT User (#{existing_str}). Revoke it " <>
            "first via Ezagent.EntityCaps.revoke/2, then re-run — granting both would " <>
            "leave the agent's git identity ambiguous " <>
            "(Ezagent.Identity.AgentGitIdentity.materialize/1 fails loud and wipes the " <>
            "directory rather than picking one)."
        )

      {:error, reason} ->
        Mix.raise("ezagent.agent.grant_git_identity failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec plan([String.t()]) :: {:ok, %{agent: URI.t(), user: URI.t()}} | {:error, term()}
  def plan([agent_str, user_str]) do
    with {:ok, agent} <- parse_typed(agent_str, "agent", :not_an_agent_uri),
         {:ok, user} <- parse_typed(user_str, "user", :not_a_user_uri) do
      {:ok, %{agent: agent, user: user}}
    end
  end

  def plan(_), do: {:error, :usage}

  @doc false
  @spec grant(URI.t(), URI.t()) :: {:ok, Ezagent.Capability.t()} | {:error, term()}
  def grant(%URI{} = agent_uri, %URI{} = user_uri) do
    admin = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.with_action(user_uri, :user_ssh_identity, :read_ssh_key)

    with :ok <- reject_conflicting_identity(agent_uri, user_uri),
         {:ok, _pid} <- ensure_started(user_uri),
         # `issue_for_action/3` derives the required cap from the Behavior's own
         # `required_caps/0` — no hand-built axes to get wrong.
         {:ok, cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, agent_uri, target),
         :ok <- Ezagent.Identity.absorb_cap(agent_uri, cap),
         :ok <-
           Ezagent.Identity.CapAbsorbAwait.await_exact(agent_uri, [cap], @absorb_timeout_ms) do
      {:ok, cap}
    end
  end

  # See moduledoc "冲突检测". Uses the CONSUMER's own selector so "what the
  # grant side calls a duplicate" and "what materialize/1 calls ambiguous" can
  # never independently drift. A cap pointing at the SAME user is not a
  # conflict (left in `conflicting == []`); only caps pointing elsewhere are.
  defp reject_conflicting_identity(agent_uri, user_uri) do
    new_instance = Ezagent.URI.instance(user_uri)

    conflicting =
      agent_uri
      |> Ezagent.Identity.AgentGitIdentity.dispatch_caps()
      |> Enum.reject(fn cap -> cap_instance(cap) == new_instance end)

    case conflicting do
      [] -> :ok
      caps -> {:error, {:conflicting_git_identity, Enum.map(caps, &cap_instance/1)}}
    end
  end

  defp cap_instance(%Ezagent.Capability{instance: %URI{} = uri}), do: uri
  defp cap_instance(%Ezagent.Capability{instance: s}) when is_binary(s), do: Ezagent.URI.new!(s)

  defp ensure_started(uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(uri) do
      {:ok, _status, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:user_not_startable, reason}}
    end
  end

  defp parse_typed(str, expected_type, error_tag) do
    uri = Ezagent.URI.new!(str)

    case Ezagent.URI.type(uri) do
      {:ok, ^expected_type} -> {:ok, uri}
      _ -> {:error, {error_tag, str}}
    end
  rescue
    _ -> {:error, {error_tag, str}}
  end
end

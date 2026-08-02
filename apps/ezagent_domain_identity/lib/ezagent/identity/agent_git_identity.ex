defmodule Ezagent.Identity.AgentGitIdentity do
  @moduledoc """
  SSH 凭据 1b — decides WHETHER an agent gets a git identity, and WHOSE, then
  hands the write to `Ezagent.Credential.GitIdentityRuntime` (core).

  ## 一条 cap 同时是三样东西

  The agent's `read_ssh_key` capability is:

  * the **switch** — hold it and the identity is materialized; don't and nothing
    happens at all (no dispatch, no files, no log line)
  * the **authorization** — it is 1a's own cap, checked by the normal step-5.5
    gate on the dispatch
  * the **pointer** — `cap.instance` IS the User whose key gets read

  **Nothing is derived.** There is deliberately no "resolve the agent's owner"
  step: `Ezagent.WorkspacePlacement.owner_of/1` returns the node's
  `RuntimeIdentity` (a federation-placement concept), not a workspace's owning
  user, and the recipe cap channel cannot express a cap pointing at a User —
  `Ezagent.Agent.Recipe.CapMint.mint/3` itself takes `kind`/`instance` as
  parameters (it is generic), but its ONLY production call site
  (`Ezagent.ActionSet.Workspace.AgentCreate.RoleStep.mint_and_grant_caps/4`,
  `role_step.ex:194-200`) hardwires `kind: :agent, instance: agent_uri` for
  every recipe-materialized agent — so a recipe cap can only ever point at the
  agent itself, never at a User. Making the cap the pointer means the switch
  and the subject are the same fact and cannot drift apart.

  Grant it with `mix ezagent.agent.grant_git_identity <agent_uri> <user_uri>`.

  ## 这也是 B2′ 与 A1 的切换点

  A1（平台持 key、agent 不持）= 不发这条 cap。切换粒度**是 agent**，不是仓库
  —— key 归 User，一个 session 里只要有一个仓库走 B2′，key 就覆盖了该 User 的
  所有仓库（见 1b design §10）。

  ## 部署契约

  同一部署内，两个 agent 是否隔离，完全取决于有没有各自发这条 cap。
  跨租户隔离靠**不共享部署**（workspace = 部署单元），代码无强制。
  """

  require Logger

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Credential.GitIdentityRuntime

  @behavior_module UserSshIdentity
  @action :read_ssh_key

  @doc """
  Materialize `agent_uri`'s git identity, if it is authorized for one.

  * `{:ok, env}` — materialized; merge `env` into the agent subprocess env
  * `{:ok, :none}` — **the default**: no cap, nothing done, nothing logged
  * `{:error, reason}` — authorized but something is misconfigured; the caller
    MUST NOT fail the spawn over it (a git identity is a capability of the
    agent, not a precondition for its existence)

  Never raises.
  """
  @spec materialize(URI.t()) :: {:ok, map()} | {:ok, :none} | {:error, term()}
  def materialize(%URI{} = agent_uri) do
    case dispatch_caps(agent_uri) do
      [] ->
        # 设计 §6.1 —— THE step that makes cap revocation take effect. Without
        # this wipe, revoking the cap only removes the env var while the key
        # stays on the agent's filesystem, fully usable via its own
        # `git -c core.sshCommand=...`. Cheap: an rm_rf on a path that does
        # not exist for nearly every agent, every spawn.
        GitIdentityRuntime.wipe(agent_uri)
        {:ok, :none}

      [cap | _] ->
        with {:ok, private_key} <- read_private_key(agent_uri, cap),
             {:ok, env} <- GitIdentityRuntime.write(agent_uri, private_key) do
          {:ok, env}
        else
          {:error, reason} ->
            # `GitIdentityRuntime.write/2` wipes on its OWN failures, but a
            # `read_private_key/2` failure happens BEFORE write is ever called
            # — nothing would clear a key left by an earlier successful spawn.
            # 设计 §6.1: every outcome except `{:ok, env}` clears the dir.
            GitIdentityRuntime.wipe(agent_uri)
            report(agent_uri, cap, reason)
        end
    end
  rescue
    # `GitIdentityDir.path/1` raises on a non-agent URI. A cleanup/materialize
    # helper must never take the spawn path down with it.
    e -> {:error, {:git_identity_materialize_crashed, Exception.message(e)}}
  end

  @doc """
  The caps this agent would dispatch with — exactly the `read_ssh_key` caps it
  holds, and nothing else.

  Public so the narrow-authorization property is directly assertable: passing
  the agent's FULL cap set to the dispatch would carry every other authority it
  owns into a credential read (`Ezagent.Credential.GrantCap`'s moduledoc states
  the same rule for the source-read path: "The caller passes this SINGLE cap
  as the dispatch caps ... never a broad set").
  """
  @spec dispatch_caps(URI.t()) :: [Ezagent.Capability.t()]
  def dispatch_caps(%URI{} = agent_uri) do
    agent_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.filter(&ssh_read_cap?/1)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # A cap whose `instance` is the wildcard `:any` is NOT a pointer — it names no
  # User. Treating it as "on" would leave `user_uri_of/1` with nothing to
  # dispatch at. Require a concrete instance: the switch and the subject are the
  # same fact, so a cap that cannot name a subject cannot be a switch.
  defp ssh_read_cap?(%Ezagent.Capability{
         behavior: @behavior_module,
         action: @action,
         instance: instance
       }),
       do: concrete_instance?(instance)

  defp ssh_read_cap?(_), do: false

  defp concrete_instance?(%URI{}), do: true
  defp concrete_instance?(s) when is_binary(s) and s != "", do: true
  defp concrete_instance?(_), do: false

  defp read_private_key(agent_uri, cap) do
    target = Ezagent.URI.with_action(user_uri_of(cap), :user_ssh_identity, @action)

    invocation = %Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: agent_uri,
        authenticated_principal: agent_uri,
        # THE narrow cap — not the agent's full set. See `dispatch_caps/1`.
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    }

    case Ezagent.Invocation.dispatch(invocation) do
      {:ok, %{private_key: key}} when is_binary(key) ->
        {:ok, key}

      # 1a deliberately separates these two. Keep them separate here: one means
      # "the operator granted a cap but never generated a key" (fix: generate),
      # the other means "a key exists but its state is corrupt" (fix: revoke +
      # regenerate). Collapsing them throws away a distinction 1a spent a full
      # review round getting right.
      {:error, :ssh_identity_absent} ->
        {:error, :owner_has_no_key}

      {:error, :ssh_identity_unavailable} ->
        {:error, {:owner_key_unavailable, :ssh_identity_unavailable}}

      {:error, reason} ->
        {:error, {:ssh_key_read_failed, reason}}

      other ->
        {:error, {:ssh_key_read_unexpected, inspect(other)}}
    end
  end

  # The cap's `instance` IS the User to read from — the pointer half of the
  # moduledoc's "one cap, three jobs".
  defp user_uri_of(%Ezagent.Capability{instance: %URI{} = uri}), do: uri

  defp user_uri_of(%Ezagent.Capability{instance: uri}) when is_binary(uri),
    do: Ezagent.URI.new!(uri)

  # Authorized-but-broken must be NOISY (the operator granted a cap and expects
  # git to work), while the no-cap case above is silent (it is the default state
  # of nearly every agent — a log line there would be pure noise).
  #
  # `reason` never carries key material: `GitIdentityRuntime` strips content
  # from its error tuples, and 1a's action errors are bare atoms.
  defp report(agent_uri, cap, reason) do
    :telemetry.execute(
      [:ezagent, :git_identity, :materialize_failed],
      %{count: 1},
      %{agent: URI.to_string(agent_uri), user: URI.to_string(user_uri_of(cap)), reason: reason}
    )

    Logger.error(
      "git identity NOT materialized for #{URI.to_string(agent_uri)} " <>
        "(authorized to read #{URI.to_string(user_uri_of(cap))}): #{inspect(reason)}. " <>
        remediation(reason)
    )

    {:error, reason}
  end

  defp remediation(:owner_has_no_key),
    do: "The User has no SSH identity — run the :generate_ssh_key action for them."

  defp remediation(:known_hosts_unconfigured),
    do:
      "No node known_hosts configured — run `mix ezagent.git.known_hosts github.com --out <path>` " <>
        "and set `config :ezagent_core, :git_known_hosts_path, \"<path>\"`."

  defp remediation({:known_hosts_unreadable, _}),
    do: "The configured :git_known_hosts_path is unreadable — check the path and permissions."

  defp remediation(_), do: ""
end

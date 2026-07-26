defmodule Ezagent.ActionSet.Session.RouteProvisioner do
  @moduledoc false

  require Logger

  alias Ezagent.ActionSet.Session.{Members, Membership}
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateTeam

  @doc false
  @spec resolve_role(String.t(), map(), term(), module()) :: URI.t() | :pending | nil
  def resolve_role(role_name, ctx, provision_key, behavior_module) when is_binary(role_name) do
    members = ctx[:read].(:members, %{})

    case Members.role_name_to_uri(members, role_name) do
      %URI{} = uri -> uri
      nil -> provision_declared_role(role_name, ctx, provision_key, behavior_module)
    end
  end

  defp provision_declared_role(role_name, ctx, provision_key, behavior_module) do
    session_uri = ctx[:self_uri]
    workspace_uri = workspace_uri_for_session(session_uri)
    owner_uri = ctx[:read].(:owner_uri, nil) || Ezagent.Entity.User.admin_uri()

    with %{} = declaration <- declared_role(role_name, ctx[:read].(:template_working_copy, %{})),
         {:ok, %URI{} = member_uri, facets} <-
           TemplateTeam.provision_declared_member(
             session_uri,
             workspace_uri,
             owner_uri,
             declaration
           ),
         {:ok, _result, effects} <-
           Membership.do_join(
             member_uri,
             system_mediated_ctx(ctx),
             facets,
             behavior_module
           ) do
      prior = Process.get(provision_key, [])
      Process.put(provision_key, prior ++ effects)

      # The newly-created holder has not completed its cap-gated self-add yet.
      # Returning its URI here would deliver the current message immediately,
      # keeping the holder busy ahead of its convergence cast and recreating the
      # Phase-A/Phase-B race. Suppress fallback routing with `:pending`; the
      # durable join cursor committed in `effects` makes self-add replay this
      # message once the holder is ready.
      :pending
    else
      # An `fill: :agent` role slot is NOT provisioned here — spawning an agent
      # inside the Session Kind's own action handler is the coupling rev6 / #912
      # forbids. It is materialized by the post-create socialware-install
      # transaction (`SessionCreator.install_session_socialware/1`). A message
      # arriving before that transaction lands must FAIL LOUDLY, not resolve to
      # `nil` and silently fall through to zero receivers (Invariant #9).
      {:error, {:agent_role_slot_materialized_at_session_create, _role, _session}} ->
        role_not_installed(session_uri, role_name)

      # A human slot awaiting runtime assignment is a NORMAL state, not a fault.
      {:error, {:human_role_slot_requires_runtime_assignment, _role, _session}} ->
        nil

      # No declaration for this role at all — the caller (`RoleResolver`) falls
      # back to workspace-level responsibility assignment, which is a legitimate
      # resolution path, so this stays quiet.
      nil ->
        nil

      other ->
        Logger.error(
          "Session route provisioning FAILED for role=#{inspect(role_name)} " <>
            "session=#{URI.to_string(session_uri)}: #{inspect(other)} — the message " <>
            "has no receiver for this role."
        )

        :telemetry.execute(
          [:ezagent, :session, :route_provision, :failed],
          %{count: 1},
          %{session_uri: session_uri, role_name: role_name, reason: other}
        )

        nil
    end
  end

  defp role_not_installed(session_uri, role_name) do
    Logger.error(
      "Session route: role=#{inspect(role_name)} is DECLARED but not installed on " <>
        "#{URI.to_string(session_uri)} — its socialware-install transaction has not " <>
        "completed (or failed). The message has no receiver. Retry once the install " <>
        "lands, or re-run `SessionCreator.install_session_socialware/1`."
    )

    :telemetry.execute(
      [:ezagent, :session, :route_provision, :role_not_installed],
      %{count: 1},
      %{session_uri: session_uri, role_name: role_name}
    )

    nil
  end

  # #161 C.1 (admission-gate over-fire fix) — realizing a member DECLARED in the
  # session's OWN template spec (`member_declarations`, resolved by `declared_role/2`)
  # is SYSTEM-MEDIATED materialization, NOT a caller-initiated cross-owner add: the
  # declaration was vetted at template author/publish + install time, and routing
  # merely lazily provisions it on first reference. Run the member `do_join` under the
  # genesis admin principal — IDENTICAL to `Materializer.join_session_members` /
  # `DefinitionAgents` at session-CREATE (both use `caller: admin_uri` for the same
  # reason) — so the admission gate does NOT pend the session's own declared members
  # just because an ordinary participant's message happened to trigger the lazy
  # provision. This is a genuinely autonomous internal principal, so both the
  # logical caller and the authenticated holder are the admin URI. A genuine
  # cross-owner PULL never
  # reaches here — that is a DIRECT `session.join` with `caller = puller` (still pends);
  # this path fires only for a role found in THIS session's `declared_role/2`.
  defp system_mediated_ctx(ctx) do
    admin = Ezagent.Entity.User.admin_uri()

    ctx
    |> Map.put(:caller, admin)
    |> Map.put(:authenticated_principal, admin)
  end

  defp workspace_uri_for_session(%URI{} = session_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, %URI{} = workspace_uri} -> workspace_uri
      :error -> Ezagent.Capability.workspace_of(session_uri)
    end
  end

  defp declared_role(role_name, working_copy)
       when is_binary(role_name) and is_map(working_copy) do
    working_copy
    |> Map.get(:member_declarations, [])
    |> Enum.find(fn
      %{role_name: ^role_name} -> true
      %{"role_name" => ^role_name} -> true
      _ -> false
    end)
  end
end

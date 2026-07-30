defmodule Ezagent.World.DispatchContract do
  @moduledoc """
  Backend-owned allowlist for actions accepted by `WorldLive`.

  Static action families are consumed by the LiveView guards and by the
  generated Tier-1 browser fixtures. Plugin-page actions remain owned by
  `PluginPageRegistry` and are folded into `accepted_actions/0`.
  """

  @groups %{
    agent:
      ~w(agents.create agents.delete agents.config.update agents.config.delete_path agents.config.repoint),
    user: ~w(users.create users.profile.save users.password.set users.disable users.enable),
    cmdk: ~w(cmdk.open cmdk.close cmdk.query cmdk.select),
    admin:
      ~w(admin.registration.save admin.smtp.save admin.smtp.test admin.smtp.update_recipient external_mirror.bind external_mirror.unbind),
    workspace_plugin:
      ~w(profile.display_name.edit profile.display_name.save profile.display_name.cancel feishu.bind feishu.unbind workspace.member.remove workspace.invite.mint workspace.invite.revoke workspace.template.save kb.query kb.ingest auto_derive.default_source.set auto_derive.credential_grant.revoke),
    # market.retract / market.restore are SERVICE-ONLY (removed from the World
    # surface): the governance retract/restore gate requires the synthetic
    # `socialware:<name>` manage capability, whose subject is a string (not an
    # openable authority) — it is constructed ONLY in a directly-built service ctx
    # (`Ezagent.ConfigGovernance.Socialware.operator_admin_ctx/2`, manifest_yaml),
    # never stored on a human principal. So no World user (admin included) can
    # authorize retract/restore via `PresenterCaps.load/1` verified caps; the
    # actions always failed `:unauthorized` and only ever "worked" via the now-
    # removed mount-snapshot cap injection. Retract/restore stay available on the
    # service path (`Socialware.retract/2`/`restore/2`, gate proven by session
    # `Ezagent.Socialware.RetractTest`).
    market: ~w(market.install market.publish),
    # NOTE: this list is the SoT for BOTH the `WorldLive` `:conversation`
    # routing guard AND the parity gate in
    # `conversation_dispatch_parity_test.exs`. Every action string that
    # `Ezagent.World.ConversationActions.handle_dispatch/3` matches must be a
    # member here (or an explicitly-documented exemption in that test).
    # `session.assign_role`/`session.fork_config`/`session.publish_template`
    # were dispatched by the React client (`main.tsx`) but were MISSING here,
    # so they fell through to the catch-all → `error:unsupported_action` (#224).
    conversation:
      ~w(chat.send chat.load_older chat.mark_displayed session.switch session.invite session.remove_participant session.assign_role session.socialware.uninstall session.create session.fork_config session.publish_template session.view.switch session.pty.open session.orchestrator.restart session.routing.add session.routing.toggle session.agent_admission.begin session.agent_admission.complete session.agent_admission.cancel)
  }

  @direct_actions ~w(sessions.join agent.api_key.put)

  @type group :: :agent | :user | :cmdk | :admin | :workspace_plugin | :market | :conversation

  @doc "Static actions for one WorldLive handler family."
  @spec actions(group()) :: [String.t()]
  def actions(group) when is_map_key(@groups, group), do: Map.fetch!(@groups, group)

  @doc "All backend-admitted `world:dispatch` actions, including plugin pages."
  @spec accepted_actions() :: [String.t()]
  def accepted_actions do
    plugin_actions =
      Ezagent.World.PluginPageRegistry.pages()
      |> Enum.flat_map(& &1.actions)

    (@direct_actions ++ Map.values(@groups) ++ plugin_actions)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end
end

defmodule EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow do
  @moduledoc """
  PR-EM-6 (SPEC §9 PR-EM-6 / §2.2) — per-adapter Cap 2 marker Behavior
  for the Feishu external-mirror adapter.

  Cap-only Behavior (`dispatchable?/0 == false`). Registered against
  `Ezagent.Entity.Session` with action `:allow_feishu` at plugin boot
  by `EzagentPluginFeishu.Application.boot`. The `cap_subject/0`
  callback on `EzagentPluginFeishu.FeishuAdapter` returns this module
  so the `Ezagent.ExternalMirror.bind/4` facade's Check 2 (per-adapter
  allow cap, SPEC §4.2) checks for:

      %{
        kind: :session,
        behavior: EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow,
        instance: <session_uri>,
        workspace_uri: <session workspace or :any>
      }

  ## data_owner = :any → workspace admin grants

  Per caps-data-ownership SPEC §3.3 (`apps/ezagent_domain_chat/...`
  alias path): `:any` means "class-wide cap, workspace admin grants".
  Operators authorize a user to use the Feishu adapter on a given
  session by granting this cap; the bind facade then enforces it
  alongside the session-level `:bind` cap (Check 1) + the adapter's
  `target_ownership_check/2` (Check 3 — Lark API membership query).

  ## Why a marker Behavior

  The cap shape needs a Behavior module so it can be registered with
  `Ezagent.CapabilityRegistry` and grants flow through the standard
  `Ezagent.Behavior.IdentityAdmin.invoke(:grant_cap, ...)` admin
  surface. The Behavior is otherwise empty — `invoke/4` raises if
  called, but `dispatchable?/0 == false` prevents
  `Ezagent.Invocation.dispatch/1` from ever finding it. Mirror of the
  reference impl in
  `apps/ezagent_domain_external_mirror/test/support/mock_publish_adapter.ex`
  (the `MockPublishAdapter.Allow` shape PR-EM-2 ships).
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:allow_feishu]

  @impl Ezagent.Behavior
  def cap_subjects,
    do: [
      {:allow_feishu, "Authorize binding the `feishu` external-mirror adapter on this session."}
    ]

  # PR-CC-2a (SPEC caps-cleanup-v1 §5.1) — per-action cap STRING.
  # FeishuAllow is cap-only (dispatchable? false) on Session Kind.
  @impl Ezagent.Behavior
  def required_caps, do: %{allow_feishu: "session.external_adapter_feishu.allow_feishu"}

  @impl Ezagent.Behavior
  def dispatchable?, do: false

  @impl Ezagent.Behavior
  def state_slice, do: :external_adapter_feishu

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(_action, _slice, _args, _ctx) do
    raise "EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow is cap-only " <>
            "(dispatchable?/0 == false). Check 2 in Ezagent.ExternalMirror.bind/4 " <>
            "is its only consumer."
  end

  @impl Ezagent.Behavior
  def interface, do: %{}

  # :any → workspace admin grants per caps-data-ownership §3.3
  @impl Ezagent.Behavior
  def data_owner(_), do: :any
end

defmodule EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow do
  @moduledoc """
  PR-EM-6 (SPEC §9 PR-EM-6 / §2.2) — per-adapter Cap 2 marker Behavior
  for the Feishu external-mirror adapter.

  Cap-only Behavior (`dispatchable?/0 == false`). Registered against
  `Ezagent.Entity.Session` with action `:allow_feishu` at plugin boot
  by the plugin's Application boot. The `cap_subject/0` callback on
  `EzagentPluginFeishu.FeishuAdapter` returns this module so the
  `Ezagent.ExternalMirror.bind/4` facade's Check 2 (per-adapter
  allow cap, SPEC §4.2) checks for:

      %{
        kind: :session,
        behavior: EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow,
        instance: <session_uri>,
        workspace_uri: <session workspace or :any>
      }

  ## data_owner = :any → workspace admin grants

  Per caps-data-ownership SPEC §3.3 (`apps/ezagent_domain_instance_message/...`
  alias path): `:any` means "class-wide cap, workspace admin grants".
  Operators authorize a user to use the Feishu adapter on a given
  session by granting this cap; the bind facade then enforces it
  alongside the session-level `:bind` cap (Check 1) + the adapter's
  `target_ownership_check/2` (Check 3 — Lark API membership query).

  ## Why a marker Behavior

  The cap shape needs a Behavior module so it can be registered with
  `Ezagent.CapabilityRegistry` and grants flow through the standard
  IdentityAdmin grant-cap admin surface. The Behavior is otherwise
  empty — `handle_allow_feishu/2` raises if called, but
  `dispatchable?/0 == false` prevents the framework dispatcher from
  ever finding it. Mirror of the reference impl in
  `apps/ezagent_domain_external_mirror/test/support/mock_publish_adapter.ex`
  (the `MockPublishAdapter.Allow` shape PR-EM-2 ships).

  ## Phase B migration (2026-05-29) — Lifecycle API

  Migrated from `use Ezagent.Behavior` to `use Ezagent.Lifecycle`
  per SPEC `2026-05-29-lifecycle-hooks-design.md` §2.3 (the simple,
  no-transients, cap-only case). This is a marker Behavior:
  `dispatchable?/0 == false`, a raising handler, no state mutation,
  no transients — so `create/1` builds an empty `state` and
  `activate/2` is the macro-injected no-op default.

  The slice key `:external_adapter_feishu` does NOT match the
  macro's auto-derived key (the last module segment `Allow` would
  derive `:allow`), so the snapshot-compat `state_slice:` override
  is used (SPEC §5 / §7 OQ-7) with the required
  `# lifecycle:state_slice_override` marker comment the Phase C grep
  gate sanctions.

  Earlier (Phase 2-f r3, 2026-05-28) this Behavior was already on the
  declarative `action/3` + `handle_<action>/2` contract.

  Custom `required_caps/0` is retained (not auto-derived) because
  the cap axis is `:session`, not the macro's default `:any`. The
  auto-derived `cap_subjects/0` is also overridden to keep the
  exact pre-migration English wording.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :external_adapter_feishu

  action :allow_feishu,
    args: %{},
    returns: :ok,
    caps: [:allow_feishu],
    description:
      "Authorize binding the `feishu` external-mirror adapter on this session.",
    modes: [:call]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # FeishuAllow is a cap-only marker Behavior registered on the Session
  # Kind — kind axis is `:session`. We override the macro-derived
  # `required_caps/0` (which defaults to `:any` axis) to keep the
  # `:session` axis the CapabilityRegistry needs to match Check 2 in
  # `Ezagent.ExternalMirror.bind/4`.

  def required_caps do
    %{
      allow_feishu: Ezagent.Capability.cap(:session, __MODULE__, :allow_feishu)
    }
  end


  def dispatchable?, do: false

  # `state_slice/0` is macro-emitted from the `state_slice:
  # :external_adapter_feishu` override above (the hand-rolled
  # `def state_slice` is gone). `init_slice/1` → `create/1`: an empty
  # PERSISTENT `state` (this marker holds no state). No transients, so
  # `activate/2` is the macro-injected no-op default.
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  # Cap-only marker — must define `handle_allow_feishu/2` to satisfy the
  # `use Ezagent.Behavior` macro's @before_compile invariant (every
  # declared action requires a matching handler). Raises identically
  # to the legacy contract clause; `dispatchable?/0 == false`
  # prevents the framework dispatcher from ever routing here.
  def handle_allow_feishu(_args, _ctx) do
    raise "EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow is cap-only " <>
            "(dispatchable?/0 == false). Check 2 in Ezagent.ExternalMirror.bind/4 " <>
            "is its only consumer."
  end

  # :any → workspace admin grants per caps-data-ownership §3.3

  def data_owner(_), do: :any
end

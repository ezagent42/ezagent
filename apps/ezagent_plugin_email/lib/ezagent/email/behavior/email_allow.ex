defmodule EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow do
  @moduledoc """
  #88 PR-1 — per-adapter Cap 2 marker Behavior for the email
  external-mirror adapter. Modeled exactly on
  `EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow`.

  Cap-only Behavior (`dispatchable?/0 == false`). Registered against
  `Ezagent.Entity.Session` with action `:allow_email` at plugin boot by
  `EzagentPluginEmail.Application.behaviors/0`. The `cap_subject/0`
  callback on `Ezagent.Email.Adapter` returns this module so the
  `Ezagent.ExternalMirror.bind/4` facade's Check 2 (per-adapter allow
  cap, SPEC §4.2) checks for:

      %{
        kind: :session,
        behavior: EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow,
        instance: <session_uri>,
        workspace_uri: <session workspace or :any>
      }

  ## data_owner = :any → workspace admin grants

  `:any` means "class-wide cap, workspace admin grants". Operators
  authorize a user to use the email adapter on a given session by granting
  this cap; the bind facade enforces it alongside the session-level
  `:bind` cap (Check 1) + the adapter's `target_ownership_check/2`
  (Check 3 — for email, a cheap address-format sanity check; the human
  verification handshake is the separate async lifecycle in PR-2).

  ## Why a marker Behavior

  The cap shape needs a Behavior module so it can be registered with
  `Ezagent.CapabilityRegistry` and grants flow through the standard
  IdentityAdmin grant-cap admin surface. Registering it is what keeps the
  `AdapterCapSubjectRegisteredTest` invariant satisfied (a real registered
  `behavior_module`, not the `nil` opt-out). The Behavior is otherwise
  empty — `handle_allow_email/2` raises if called, but
  `dispatchable?/0 == false` prevents the framework dispatcher from ever
  finding it.

  ## Lifecycle API

  Uses `use Ezagent.Lifecycle` (the cap-only, no-transients case). The
  slice key `:external_adapter_email` does NOT match the macro's
  auto-derived key (the last segment `Allow` would derive `:allow`), so
  the snapshot-compat `state_slice:` override is used with the required
  `# lifecycle:state_slice_override` marker comment the Phase C grep gate
  sanctions.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :external_adapter_email

  action(:allow_email,
    args: %{},
    returns: :ok,
    caps: [:allow_email],
    description: "Authorize binding the `email` external-mirror adapter on this session.",
    modes: [:call]
  )

  # Cap-only marker Behavior registered on the Session Kind — kind axis is
  # `:session`. Override the macro-derived `required_caps/0` (which defaults
  # to `:any` axis) to keep the `:session` axis the CapabilityRegistry needs
  # to match Check 2 in `Ezagent.ExternalMirror.bind/4`.
  def required_caps do
    %{
      allow_email: Ezagent.Capability.cap(:session, __MODULE__, :allow_email)
    }
  end

  def dispatchable?, do: false

  # `state_slice/0` is macro-emitted from the override above. `create/1`:
  # an empty PERSISTENT `state` (this marker holds no state). No
  # transients, so `activate/2` is the macro-injected no-op default.
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  # Cap-only marker — must define `handle_allow_email/2` to satisfy the
  # macro's @before_compile invariant (every declared action requires a
  # matching handler). Raises identically to the Feishu reference;
  # `dispatchable?/0 == false` prevents the dispatcher from ever routing
  # here.
  def handle_allow_email(_args, _ctx) do
    raise "EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow is cap-only " <>
            "(dispatchable?/0 == false). Check 2 in Ezagent.ExternalMirror.bind/4 " <>
            "is its only consumer."
  end

  # :any → workspace admin grants per caps-data-ownership §3.3
  def data_owner(_), do: :any
end

defmodule Ezagent.SystemPrincipal.Catalog do
  @moduledoc """
  The closed allowlist of system principal URIs and their permitted caps.

  Any `system://` URI used as a dispatch principal MUST appear here.
  `:ezagent_plugin_check` enforces this at compile time (Issue 3);
  the runtime `SystemPrincipal.ensure/1` enforces it at boot;
  invariant test `no_admin_caps_fallback_test.exs` is the test-time gate.

  Adding a 15th principal requires:
  1. Add row here.
  2. Update SPEC `2026-05-25-caps-cleanup-v1.md` §4.1 catalog table.
  3. Ship in a separate PR (review surface = "are we adding ambient authority?").

  Per `feedback_let_it_crash_no_workarounds` — every entry is closed;
  there is no fallback path that mints an ad-hoc principal.

  ## Cap structs (PR-CC-2-v2)

  The catalog records `%Ezagent.Capability{}` struct values. Pre-PR-CC-2-v2
  (PR-CC-1's window) the catalog held string-cap lists and PR-CC-1's
  `SystemPrincipal.caps/1` bridge minted ONE wildcard cap per non-empty
  entry — a coarse-grained authorization slip until the struct-shape
  conversion landed.

  PR-CC-2-v2 (SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md`
  §5) closes that gap. Each entry's struct(s) precisely encode the
  Behavior's actual `required_caps/0` shape, so dispatch step 5.5's
  `holds_cap?/2` consults a structurally narrowed cap set instead of
  a uniform wildcard. Two principals retain full-wildcard caps:
  `system://bootstrap` (the all-caps invariant per Decision #81 + SPEC
  v3 §4.4) and `system://mix-task` (operator-driven; same authority as
  admin User per in-VM trust §10.5). All others are narrowed.

  ## Deviations from SPEC §5 provisional table

  The PR-CC-2-v2 implementing subagent verified each action atom
  against the actual `Behavior.<Module>.actions/0` on main and corrected
  the SPEC's provisional atoms:

  - `system://chat-router` originally had `session.chat.system_message` —
    `:system_message` is NOT an action on `Behavior.Chat` (the action
    list is `[:send, :receive, :join, :leave, :set_working_copy]`); the
    string was a dead cap. The struct entry KEEPS only `:send` — the
    only chat-router action that actually fires in dispatch.
  - `system://chat-reply` originally had `session.chat.reaction` —
    same situation; `:reaction` is not an action. KEEPS only `:send`.
  - `system://template-materialize` originally had `workspace.template.*` —
    `workspace.template.*` doesn't structurally map (Template Behavior
    lives on AgentTemplate/SessionTemplate Kinds, not Workspace). The
    intent was "template materialization across all template actions
    + spawning sessions"; mapped to a `Behavior.Template :any-action`
    cap on the `:any`-Kind axis (template:// is cross-cutting; SPEC §2b
    Template.workspace_scoped? = false) + the session-spawning cap.
  - `system://session-internal` originally had `workspace.workspace.read` —
    Workspace has no `:read` action (its read actions are `:list_members`,
    `:list_templates`, etc.). Mapped to a `Behavior.Workspace :any-action`
    cap so session-internal can call any read-shaped workspace action;
    if narrowed later, this becomes the explicit list.

  Refinement on the `:any-action` shape: the cap struct doesn't carry
  an `:action` field (per SPEC §4 footnote — action is the map key in
  `required_caps/0`). When a system principal needs authority across
  multiple actions of one Behavior, we hold ONE cap with the matching
  `kind` + `behavior` axis; `Capability.matches?/2` ignores action
  axis (since it's not on the struct), so the cap matches every action
  on that Behavior. This is structurally equivalent to "behavior wildcard"
  while keeping the per-Kind narrowing.
  """

  alias Ezagent.Capability

  # Aliases for the Behavior modules referenced below. Inline-aliased
  # for readability; lazy-loaded at compile time so behavior modules
  # from non-loaded apps (e.g. plugin Behaviors during a core-only
  # build) don't break.
  alias Ezagent.Behavior.Chat
  alias Ezagent.Behavior.ExternalMirror
  alias Ezagent.Behavior.ExternalMirrorWorker
  alias Ezagent.Behavior.IdentityAdmin
  alias Ezagent.Behavior.Template
  alias Ezagent.Behavior.Workspace

  # The bootstrap structural sentinel — granted_by/granted_at on the
  # generated wildcard cap so `admin_invariant?/1` recognises it.
  @bootstrap_granted_by URI.parse("system://bootstrap/default")
  @bootstrap_granted_at ~U[2026-01-01 00:00:00Z]

  defp bootstrap_wildcard do
    %Capability{
      kind: :any,
      behavior: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: @bootstrap_granted_by,
      granted_at: @bootstrap_granted_at
    }
  end

  @doc """
  The 14-entry closed allowlist mapped from principal URI →
  `[%Capability{}]` cap list.

  Implemented as a function (not a module attribute) so the bootstrap
  wildcard's granted_by/granted_at can use `@bootstrap_granted_by` +
  `@bootstrap_granted_at` directly without compile-time DateTime
  literal limitations.

  Use `caps_for!/1` and `member?/1` for the public API; this is exported
  so the no-wildcard invariant test (`no_wildcard_system_principals_test.exs`,
  SPEC §5) can iterate entries directly.
  """
  @spec entries() :: [{String.t(), [%Ezagent.Capability{}]}]
  def entries do
    [
      {"system://bootstrap", [bootstrap_wildcard()]},
      {"system://boot-reconciler",
       [
         # boot reconciler dispatches against external_mirror Behavior
         # on Session Kind (bind/unbind/list_bindings) — matches the
         # original `session.external_mirror.*` glob via the
         # behavior-wildcard pattern.
         Capability.cap(:session, ExternalMirror, :any)
       ]},
      {"system://adapter-install",
       [
         # adapter-install fires session.<flavor>.bind — the bind action
         # is the ExternalMirror Behavior's gate. Narrowed to bind.
         Capability.cap(:session, ExternalMirror, :bind)
       ]},
      {"system://chat-router",
       [
         # Deviation from SPEC §5 provisional table: the original string
         # `session.chat.system_message` referenced a non-existent action;
         # only :send is kept.
         Capability.cap(:session, Chat, :send)
       ]},
      {"system://chat-reply",
       [
         # Deviation: original string `session.chat.reaction` referenced
         # a non-existent action; only :send is kept.
         Capability.cap(:session, Chat, :send)
       ]},
      {"system://worker-publish",
       [
         Capability.cap(:external_mirror_worker, ExternalMirrorWorker, :publish)
       ]},
      {"system://template-materialize",
       [
         # Deviation: original `workspace.template.*` doesn't structurally
         # map (Template lives on AgentTemplate/SessionTemplate). Mapped
         # to a Template Behavior cap on :any-Kind (template:// is
         # cross-cutting). The session-spawn half of the original glob
         # `session.*` becomes a Chat-wildcard cap on Session Kind.
         Capability.cap(:any, Template, :any),
         Capability.cap(:session, Chat, :any)
       ]},
      {"system://orchestrator-tools",
       [
         # `session.*` → Chat behavior on Session (orchestrator tools
         # write into the session's chat slice).
         Capability.cap(:session, Chat, :any)
       ]},
      {"system://session-internal",
       [
         # Deviation: original `workspace.workspace.read` mapped to a
         # Workspace Behavior wildcard cap so session-internal can read
         # any workspace state. Original `session.chat.*` stays.
         Capability.cap(:session, Chat, :any),
         Capability.cap(:workspace, Workspace, :any)
       ]},
      {"system://agent-internal",
       [
         # `user.identity.grant_cap` → IdentityAdmin Behavior on User Kind.
         Capability.cap(:user, IdentityAdmin, :grant_cap)
       ]},
      {"system://workspace-loader",
       [
         # `workspace.workspace.*` → Workspace Behavior on Workspace Kind.
         Capability.cap(:workspace, Workspace, :any)
       ]},
      {"system://mix-task",
       [
         # Operator-driven; same authority as admin User by deployment
         # contract (in-VM trust model §10.5). Wildcard cap is
         # explicitly exempted from the no-wildcard invariant test.
         bootstrap_wildcard()
       ]},
      {"system://feishu-binding-policy",
       [
         # `user.identity.grant_cap` → IdentityAdmin Behavior on User.
         Capability.cap(:user, IdentityAdmin, :grant_cap)
       ]},
      {"system://lv-anon-mount", []}
    ]
  end

  @doc "Is this URI a registered system principal?"
  @spec member?(URI.t() | String.t()) :: boolean()
  def member?(uri) do
    key = normalize(uri)
    Enum.any?(entries(), fn {entry_uri, _caps} -> entry_uri == key end)
  end

  @doc """
  Permitted caps for this principal. Raises if not in catalog.

  Per `feedback_let_it_crash_no_workarounds` — bad URI is a programmer
  error, not a degradable runtime state.

  Returns `[%Ezagent.Capability{}]` (struct shape, post-PR-CC-2-v2).
  """
  @spec caps_for!(URI.t() | String.t()) :: [%Ezagent.Capability{}]
  def caps_for!(uri) do
    key = normalize(uri)

    case Enum.find(entries(), fn {entry_uri, _caps} -> entry_uri == key end) do
      {_uri, caps} ->
        caps

      nil ->
        raise ArgumentError,
              "#{key} is not in Ezagent.SystemPrincipal.Catalog " <>
                "(SPEC caps-cleanup-v1 §4.1). " <>
                "Add the row to Catalog + SPEC + open a separate PR."
    end
  end

  @doc "List every catalog URI (for invariant test §9.5)."
  @spec uris() :: [String.t()]
  def uris, do: Enum.map(entries(), fn {uri, _caps} -> uri end)

  defp normalize(%URI{} = u), do: URI.to_string(u)
  defp normalize(s) when is_binary(s), do: s
end

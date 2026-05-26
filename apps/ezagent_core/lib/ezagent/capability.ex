defmodule Ezagent.Capability do
  @moduledoc """
  Capability — a Push-based authorization grant carried in `ctx.caps`.

  A capability matches an `Ezagent.Invocation` when all FOUR fields
  match (with `:any` acting as wildcard for `kind` / `behavior` /
  `instance` / `workspace_uri`):

  - `kind` — Kind type atom (e.g. `:echo`); `:any` matches all
  - `behavior` — Behavior module ref (e.g. `Ezagent.Behavior.Echo`);
    `:any` matches all
  - `instance` — target URI, scope tuple, or `:any`
  - `workspace_uri` — Phase 9 PR-3 (SPEC v3 §4): the
    `workspace://<workspace>` URI the cap is scoped to. `:any` is
    the structural cross-workspace marker reserved for the
    bootstrap admin cap + explicit cross-workspace grants. Required
    on construction — `@enforce_keys` rejects pre-PR-3 4-field caps
    at compile time so no silent drops can slip past.

  `revoke/2` is admin-protected per Decision #81: `entity://user/system/admin`'s
  all-caps capability (`%Ezagent.Capability{kind: :any, behavior: :any,
  instance: :any, workspace_uri: :any, ...}` granted_by
  `system://bootstrap/default`) is a structural invariant and cannot
  be removed. The check lives here at the data-layer boundary so any
  caller path is forced through one chokepoint.
  """

  @enforce_keys [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]
  defstruct [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]

  @type scope_tuple ::
          {:within_session, URI.t()}
          | {:within_workspace, URI.t()}
          | {:spawned_by, URI.t()}

  @type t :: %__MODULE__{
          kind: atom() | :any,
          behavior: module() | :any,
          instance: URI.t() | :any | scope_tuple(),
          workspace_uri: URI.t() | :any,
          granted_by: URI.t() | :plugin_declared,
          granted_at: DateTime.t() | :compile_time
        }

  # Sentinel values for declarative caps (e.g. those returned by
  # `Behavior.required_caps/0`). Recorded here so callers using
  # `function/1` patterns can match them as well.
  @plugin_declared_granter :plugin_declared
  @compile_time_granted_at :compile_time

  @doc """
  Action atom for cap declarations: `:any` action axis.

  Provided so a Behavior author writing `required_caps/0` can declare a
  catch-all "any action on this Behavior" cap (used by
  `:ezagent_plugin_check` check 11d as the wildcard-action escape hatch
  for orchestrator-style Behaviors).
  """
  @spec any_action() :: :any
  def any_action, do: :any

  @doc """
  Construct a declarative capability for use in `Behavior.required_caps/0`
  or for issuing a grant.

  The 3-arity form fills `instance` and `workspace_uri` with `:any` (matches
  any target / any workspace) — the common shape for `required_caps/0`
  declarations. The 5-arity form takes explicit `instance` and
  `workspace_uri` for grant sites that need narrowing.

  `granted_by` defaults to `:plugin_declared` (sentinel meaning "this is a
  declarative requirement, not an issued grant"); `granted_at` defaults to
  `:compile_time`. At grant time (`Identity.grant_cap/3` etc.), callers
  override these fields to the actual granter URI + timestamp.

  ## Examples

      # required_caps/0 declaration
      Capability.cap(:chat, Ezagent.Behavior.Chat, :send)
      # => %Capability{kind: :chat, behavior: Ezagent.Behavior.Chat, action: removed,
      #                instance: :any, workspace_uri: :any,
      #                granted_by: :plugin_declared,
      #                granted_at: :compile_time}

      # narrow grant
      Capability.cap(:chat, Chat, :send, session_uri, workspace_uri)

  ## Action axis

  The `action` argument is currently NOT stored in the struct (the
  struct has 6 fields; action is encoded inside the `behavior` axis +
  the action atom keyed in `Behavior.required_caps/0`). The helper
  accepts `action` for forward-compatible UX symmetry with PR-CC-2-v2's
  Behavior author API (`Capability.cap(:chat, Chat, :send)` is the
  recommended call shape per SPEC §2) and to make the call site readable
  — the action atom is the key in the `required_caps/0` map, so
  duplication here is intentional documentation. Future SPECs may grow
  the struct to record action; for now it's a documented no-op argument
  on the constructor.
  """
  @spec cap(atom() | :any, module() | :any, atom() | :any) :: t()
  def cap(kind, behavior, _action) when is_atom(kind) and is_atom(behavior) do
    %__MODULE__{
      kind: kind,
      behavior: behavior,
      instance: :any,
      workspace_uri: :any,
      granted_by: @plugin_declared_granter,
      granted_at: @compile_time_granted_at
    }
  end

  @spec cap(
          atom() | :any,
          module() | :any,
          atom() | :any,
          URI.t() | :any | scope_tuple(),
          URI.t() | :any
        ) :: t()
  def cap(kind, behavior, _action, instance, workspace_uri)
      when is_atom(kind) and is_atom(behavior) do
    %__MODULE__{
      kind: kind,
      behavior: behavior,
      instance: instance,
      workspace_uri: workspace_uri,
      granted_by: @plugin_declared_granter,
      granted_at: @compile_time_granted_at
    }
  end

  @doc """
  Does this capability authorize the given invocation?

  Matches kind (Kind type atom, e.g. `:echo`), behavior (module, e.g.
  `Ezagent.Behavior.Echo`), instance (the target URI), and
  `workspace_uri` (the workspace scope the action targets, derived
  via `cap_for_action/3`). `:any` matches everything in that
  position.

  ## Scope-bounded instance shapes (Phase 7 PR 42 / D7-3)

  The `instance` field may also be one of three tuple shapes that
  express bounded delegation:

  - `{:within_session, %URI{} = session_uri}` — matches when the
    needed cap's instance URI is `session_uri` itself or a sub-URI
    of it (prefix match on `URI.to_string/1`). Used by the
    orchestrator's scope-bounded delegation cap so it can act
    within its own session without becoming a full admin.

  - `{:within_workspace, %URI{} = workspace_uri}` — Phase 7
    completion PR-1 (SPEC §1.4). Matches when the needed cap's
    instance URI's workspace segment equals `workspace_uri`. Used
    by the orchestrator's delegated `Behavior.Template` caps (#3/#4)
    so it can read/write/instantiate templates in its OWN workspace
    without a per-name cap. NARROWER than `:any`, MORE specific than
    a URI cap — cross-workspace template access is denied (two-tenant
    isolation holds). The needed URI's workspace is derived via the
    same `workspace_of/1` `cap_for_action/3` uses, so the two sides
    stay structurally aligned.

  - `{:spawned_by, %URI{} = principal_uri}` — matches when the
    needed cap's instance URI is in the lineage spawned by
    `principal_uri`. **PR 42 ships a structurally compliant
    placeholder that returns false** — actual lineage tracking
    arrives with PR 40 (`Ezagent.Entity.Agent.spawn/4` populates an
    `Agent.spawned_by` slice field) + a registry lookup wired
    here. Until PR 40, holding a `{:spawned_by, _}` cap matches
    nothing — denial defaults are correct.

  Both shapes preserve the existing CapBAC contract: the cap is
  more specific, not more permissive. Any cap with a scope tuple
  is bounded by the scope; `:any` remains the only true wildcard.

  ## Workspace dimension (Phase 9 PR-3 / SPEC v3 §4)

  Adds workspace scoping as a fourth match dimension. Concrete
  `workspace://X` cap matches only `workspace://X` needed; `:any`
  cap is cross-workspace (reserved for admin + explicit
  cross-workspace grants). Without this dimension, a cap granted in
  workspace A would silently authorize action on workspace B's
  entities sharing the same name (e.g. both workspaces have a
  `demo` session).
  """
  @spec matches?(t(), %{
          required(:kind) => atom(),
          required(:behavior) => module(),
          required(:instance) => URI.t(),
          required(:workspace_uri) => URI.t() | :any
        }) :: boolean()
  def matches?(%__MODULE__{} = cap, %{kind: k, behavior: b, instance: i, workspace_uri: w}) do
    field_match?(cap.kind, k) and
      field_match?(cap.behavior, b) and
      instance_match?(cap.instance, i) and
      workspace_match?(cap.workspace_uri, w)
  end

  # Kind + behavior fields use plain `:any` or exact equality.
  defp field_match?(:any, _), do: true
  defp field_match?(same, same), do: true
  defp field_match?(_, _), do: false

  # Instance field additionally honors the two scope tuples (D7-3).
  defp instance_match?(:any, _), do: true

  defp instance_match?({:within_session, %URI{} = session_uri}, %URI{} = needed_instance) do
    needed_str = URI.to_string(needed_instance)
    session_str = URI.to_string(session_uri)

    # Match if needed URI is the session URI itself, or a sub-URI of
    # it (e.g. `session://default/team-alpha/main?action=chat.send` is within
    # `session://default/team-alpha/main`). String prefix is sufficient given URI
    # canonical form; we add a `/` boundary check to avoid false
    # positives like `session://default/team-alpha/main2` matching `{:within_session,
    # session://default/team-alpha/main}`.
    needed_str == session_str or
      String.starts_with?(needed_str, session_str <> "/")
  end

  defp instance_match?({:within_workspace, %URI{} = workspace_uri}, %URI{} = needed_instance) do
    # Phase 7 completion PR-1 (SPEC §1.4) — a `{:within_workspace, W}`
    # cap matches a needed action on a per-tenant URI iff the URI's
    # workspace segment equals `W`. `workspace_of/1` does the structural
    # extraction (and returns `:any` for cross-cutting schemes like
    # `system://`, which a workspace-bounded cap must NOT match — only
    # `:any` is the true wildcard, never `{:within_workspace, _}`).
    case workspace_of(needed_instance) do
      %URI{} = needed_ws -> URI.to_string(needed_ws) == URI.to_string(workspace_uri)
      :any -> false
    end
  end

  defp instance_match?({:spawned_by, %URI{} = principal_uri}, %URI{} = needed_instance) do
    # PR 40 ships the Ezagent.AgentLineage ETS registry that
    # `Ezagent.Entity.Agent.spawn/4` populates. CapBAC step 5.5 reads
    # it here — O(1) ETS lookup, no dispatch. Walks the lineage
    # chain from needed_instance up to a depth bound to check if
    # principal_uri appears in the chain (inclusive — a principal
    # is in its own lineage).
    Ezagent.AgentLineage.spawned_in_lineage?(needed_instance, principal_uri)
  end

  # Two concrete `%URI{}` instances — compare by canonical string form
  # rather than struct equality.
  #
  # WHY this is the correct equality:
  #
  #   URI.parse/1 (deprecated since Elixir 1.13) sets the legacy
  #   `authority` field; URI.new/1 (which `Ezagent.URI.parse!/1` uses)
  #   leaves `authority: nil`. Both yield identical canonical strings
  #   for the same URI, but as structs they differ. Held caps are
  #   deserialized from `users.caps_json` / `kind_snapshots` via
  #   `Capability.from_map/1` which currently routes through
  #   `URI.parse/1`; needed-cap instances at dispatch time come from
  #   `Ezagent.URI.instance/1` operating on `URI.new!/1`-produced
  #   structs. The two halves disagree on the `authority` field, so
  #   the prior `defp instance_match?(same, same)` clause silently
  #   denied every narrow cap with a concrete URI instance — the
  #   precise regression unmasked by PR-CC-2-v2 (#354) + #358 (the
  #   transitional wildcard bridge that previously masked all narrow
  #   denials was removed; see SPEC
  #   `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md`
  #   §3 + the wildcard-cap-fix forensic note).
  #
  # By comparing `URI.to_string/1` outputs we match the
  # `workspace_match?/2` clause directly above — same canonical-string
  # semantic across both axes — and we accept whichever parser the
  # producer happened to use without introducing a back-compat shim
  # for `authority: "x"` ↔ `authority: nil` on the struct level.
  defp instance_match?(%URI{} = held, %URI{} = needed),
    do: URI.to_string(held) == URI.to_string(needed)

  defp instance_match?(same, same), do: true
  defp instance_match?(_, _), do: false

  # Workspace field — concrete URI must equal-string-match;
  # `:any` on either side is the cross-workspace marker.
  defp workspace_match?(:any, _), do: true
  defp workspace_match?(_, :any), do: true

  defp workspace_match?(%URI{} = held, %URI{} = needed),
    do: URI.to_string(held) == URI.to_string(needed)

  defp workspace_match?(_, _), do: false

  @doc """
  Remove a capability from a MapSet of caps.

  Refuses to remove the admin all-caps invariant — `entity://user/system/admin`'s
  quadruple-`:any` capability granted_by `system://bootstrap/default`
  is structural per Decision #81 + SPEC v3 §4.4 and would break the
  bootstrap principal.

  Returns `{:ok, new_caps}` on success, `{:error, :cannot_revoke_admin}`
  if the input cap is the admin all-caps invariant.
  """
  @spec revoke(MapSet.t(t()), t()) :: {:ok, MapSet.t(t())} | {:error, :cannot_revoke_admin}
  def revoke(%MapSet{} = caps, %__MODULE__{} = cap) do
    if admin_invariant?(cap) do
      {:error, :cannot_revoke_admin}
    else
      {:ok, MapSet.delete(caps, cap)}
    end
  end

  @doc false
  # SPEC v3 §4.4 — admin's structural invariant gains `workspace_uri:
  # :any` so the cap is cross-workspace by structural design.
  def admin_invariant?(%__MODULE__{
        kind: :any,
        behavior: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: %URI{scheme: "system", host: "bootstrap"}
      }),
      do: true

  def admin_invariant?(%__MODULE__{}), do: false

  @doc """
  Is `cap` a cross-workspace cap (arity-1, structural form)?

  Phase 9 PR-4 (SPEC v3 §5.1) — returns true when the cap's
  `workspace_uri` is `:any`. Retained for back-compat with
  call-sites that don't have a caller URI in hand (e.g. some test
  fixtures and the `to_map/1` serialization sanity check).

  New code should prefer `cross_workspace?/2` which also honors the
  membership-based bypass per SPEC v3 §13.3.
  """
  @spec cross_workspace?(t()) :: boolean()
  def cross_workspace?(%__MODULE__{workspace_uri: :any}), do: true
  def cross_workspace?(%__MODULE__{}), do: false

  @doc """
  Is `cap` a cross-workspace cap OR is the caller a member of
  `workspace://system`?

  Phase 9 PR-8 (SPEC v3 §13.3) — Keycloak realm-admin model. ANY
  cap held by a `workspace://system` member is treated as
  cross-workspace by membership (not by explicit `:any` grant on
  the cap itself). Regular users still need a `workspace_uri: :any`
  cap to dispatch across workspaces — only system-workspace
  membership grants the structural bypass.

  Used by `Ezagent.Kind.Runtime` step 5.6 to decide whether to
  override workspace isolation when caller and target differ.
  """
  @spec cross_workspace?(t(), URI.t() | :system | nil) :: boolean()
  def cross_workspace?(%__MODULE__{workspace_uri: :any}, _caller_uri), do: true

  def cross_workspace?(%__MODULE__{}, %URI{} = caller_uri) do
    home_is_system?(caller_uri) or member_of_system?(caller_uri)
  end

  # `:system` (atom) caller + `nil` caller paths: degraded — cannot
  # derive a workspace, so no membership-based bypass. The runtime's
  # step 5.6 has its own `:system` short-circuit before calling here,
  # so this branch fires only for unusual callers (test fixtures).
  def cross_workspace?(%__MODULE__{}, _), do: false

  # Caller's HOME workspace IS system (admin's structural URI:
  # `entity://user/system/admin`). Pre-existing structural path.
  defp home_is_system?(caller_uri) do
    case workspace_of_caller_safe(caller_uri) do
      %URI{} = workspace -> URI.to_string(workspace) == "workspace://system"
      _ -> false
    end
  end

  # SPEC v2 PR-D (Allen 2026-05-24): caller is a MEMBER of
  # workspace://system. The "Promote to system" admin action uses
  # this path — a regular user (`entity://user/<their-ws>/<name>`)
  # gains cross-workspace authority by membership, not by a special
  # URI host. Lazy lookup via apply/3 to avoid compile-time core →
  # workspace circular dep.
  defp member_of_system?(%URI{} = caller_uri) do
    if Code.ensure_loaded?(Ezagent.Workspace.Store) and
         function_exported?(Ezagent.Workspace.Store, :get_by_name, 1) do
      case apply(Ezagent.Workspace.Store, :get_by_name, ["system"]) do
        %{members: members} when is_list(members) ->
          caller_str = URI.to_string(caller_uri)
          Enum.any?(members, fn m -> URI.to_string(m) == caller_str end)

        _ ->
          false
      end
    else
      false
    end
  end

  defp workspace_of_caller_safe(%URI{} = uri) do
    try do
      workspace_of(uri)
    rescue
      _ -> :any
    end
  end

  @doc """
  Derive the workspace scope of a target URI.

  SPEC v3 §4.2 / §5.3. Promoted from private in Phase 9 PR-4 so
  `Ezagent.Kind.Runtime` step 5.6 can reuse the same workspace
  derivation that `cap_for_action/3` uses for the `needed` map —
  keeping the two sides in lock-step structurally.

  - `entity://<type>/<workspace>/<name>` →
    `Ezagent.URI.entity_workspace_uri/1` (PR-2 — structural)
  - `session://<template>/<workspace>/<name>` →
    workspace path segment (PR-7 — structural, no registry lookup)
  - `template://<type>/<workspace>/<name>` →
    workspace path segment (PR-7)
  - `resource://<type>/<workspace>/<name>` →
    workspace path segment (PR-7)
  - `workspace://<name>` → the URI itself
  - `system://`, unknown schemes → `:any`
    (cross-cutting; workspace boundary doesn't apply)

  `:any` for a target means "cross-workspace by structural design"
  — step 5.6 should skip the isolation check for these.

  ## PR-7 — WorkspaceRegistry demoted to consistency cache

  Before PR-7, `workspace_of/1` for `session://` consulted
  `Ezagent.WorkspaceRegistry`. After URI unification, the workspace
  is in the URI path — extraction is O(1) string split. The registry
  is retained for back-edge lookups by code that hasn't migrated yet
  (e.g. tooling that holds a session URI and wants to know its
  workspace without re-parsing). Per SPEC v3 §3.6, every registry
  binding MUST equal the workspace segment of the URI it's bound
  for — guarded by `all_per_tenant_uris_have_workspace_test.exs`.
  """
  @spec workspace_of(URI.t()) :: URI.t() | :any
  def workspace_of(%URI{scheme: "entity"} = uri) do
    Ezagent.URI.entity_workspace_uri(%URI{uri | query: nil, fragment: nil})
  end

  def workspace_of(%URI{scheme: "session"} = uri),
    do: workspace_from_3seg_path(%URI{uri | query: nil, fragment: nil})

  def workspace_of(%URI{scheme: "template"} = uri),
    do: workspace_from_3seg_path(%URI{uri | query: nil, fragment: nil})

  def workspace_of(%URI{scheme: "resource"} = uri),
    do: workspace_from_3seg_path(%URI{uri | query: nil, fragment: nil})

  def workspace_of(%URI{scheme: "workspace"} = uri),
    do: %URI{uri | query: nil, fragment: nil}

  def workspace_of(%URI{scheme: "system"}), do: :any

  # Catch-all for test-only schemes (e.g. `probecli://`, `test://`)
  # and any future scheme not yet wired through workspace derivation.
  # Defaults to `:any` (cross-workspace) so unknown schemes don't
  # silently fail with FunctionClauseError — production paths are
  # constrained by `Ezagent.URI.SchemeRegistry` ETS allowlist per
  # SPEC v2 §5.8, so this only fires for test fixtures using
  # unregistered schemes.
  def workspace_of(%URI{}), do: :any

  # SPEC v3 §3.6 (Phase 9 PR-7) — extract the workspace URI from a
  # 3-segment per-tenant URI path. Shared by session/template/resource
  # scheme handlers above. parse!/1 guarantees the 3-segment shape;
  # hand-constructed URIs bypassing parse!/1 raise here (structural
  # programming error — let it crash rather than mask).
  #
  # NB: a URI like `session://default/team-alpha/main` parses to
  # `%URI{host: "default", path: "/default/main"}`. The path's first
  # segment is the workspace name; the second is the instance name.
  # The `<type>` axis lives in `host`, NOT in the path.
  defp workspace_from_3seg_path(%URI{path: "/" <> rest}) do
    case String.split(rest, "/", parts: 2) do
      [workspace_name, _name] when workspace_name != "" ->
        URI.new!("workspace://" <> workspace_name)

      _ ->
        raise ArgumentError,
              "URI does not have a 3-segment authority — expected " <>
                "<scheme>://<type>/<workspace>/<name>, got path: #{inspect("/" <> rest)}"
    end
  end

  defp workspace_from_3seg_path(%URI{} = uri) do
    raise ArgumentError,
          "URI has no path; cannot extract workspace segment: #{inspect(URI.to_string(uri))}"
  end

  @doc """
  Serialize a Capability to a JSON-safe map (for `users.caps_json`
  storage per Phase 4-completion Spec 05 Part A).

  Atoms become strings; modules become strings; URIs become strings.
  `workspace_uri` is serialized via `uri_or_any_to_string/1` (SPEC v3
  §4 — `:any` round-trips as `"any"`). Inverse of `from_map/1`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = cap) do
    %{
      "kind" => atom_or_module_to_string(cap.kind),
      "behavior" => atom_or_module_to_string(cap.behavior),
      "instance" => uri_or_any_to_string(cap.instance),
      "workspace_uri" => uri_or_any_to_string(cap.workspace_uri),
      "granted_by" => uri_or_any_to_string(cap.granted_by),
      "granted_at" => DateTime.to_iso8601(cap.granted_at)
    }
  end

  @doc """
  Deserialize a Capability from a JSON-decoded map.

  SPEC v3 §4 — pre-PR-3 caps_json rows lack the `workspace_uri`
  key; per the "no back-compat shim" rule (memory
  `feedback_let_it_crash_no_workarounds` + SPEC v3 §8 wipe-and-
  rebuild), the DB is reset on Phase 9 migration. To preserve
  round-trip soundness on test fixtures however, a missing key
  defaults to `:any` (the cap won't be authored without the field
  in any post-PR-3 code path).
  """
  @spec from_map(map()) :: t()
  def from_map(%{} = m) do
    %__MODULE__{
      kind: string_to_atom_or_module(Map.get(m, "kind")),
      behavior: string_to_atom_or_module(Map.get(m, "behavior")),
      instance: string_to_uri_or_any(Map.get(m, "instance")),
      workspace_uri: string_to_uri_or_any(Map.get(m, "workspace_uri", "any")),
      granted_by: string_to_uri_or_any(Map.get(m, "granted_by")),
      granted_at: parse_datetime(Map.get(m, "granted_at"))
    }
  end

  defp atom_or_module_to_string(:any), do: "any"
  defp atom_or_module_to_string(value) when is_atom(value), do: Atom.to_string(value)

  defp string_to_atom_or_module("any"), do: :any

  defp string_to_atom_or_module(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "Elixir.") ->
        String.to_existing_atom(s)

      Regex.match?(~r/^[a-z_][a-z0-9_]*$/, s) ->
        String.to_existing_atom(s)

      true ->
        String.to_existing_atom("Elixir." <> s)
    end
  rescue
    ArgumentError -> :any
  end

  defp uri_or_any_to_string(:any), do: "any"
  defp uri_or_any_to_string(%URI{} = u), do: URI.to_string(u)

  defp string_to_uri_or_any("any"), do: :any
  defp string_to_uri_or_any(s) when is_binary(s), do: URI.parse(s)

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  @doc """
  Compute the `needed` cap shape for a given (Kind module, action,
  target URI) tuple — for dispatch step 5.5 to feed into `matches?/2`.

  Phase 3d (P3-D6 hard flip + #P1-8): the target URI is required so
  we can extract the `instance` part (e.g. `session://default/team-alpha/main` from
  `session://default/team-alpha/main?action=chat.send`). `behavior` is looked up via
  `BehaviorRegistry.lookup(kind_module, action)` — same lookup
  `Kind.Runtime` does for invoke routing.

  ## Workspace derivation (Phase 9 PR-3 / SPEC v3 §4.2)

  `workspace_uri` is derived from the target URI:

  - `entity://<type>/<workspace>/<name>` — `Ezagent.URI.entity_workspace_uri/1`
  - `session://<template>/<name>` — `Ezagent.WorkspaceRegistry.lookup/1`
    (raises if unbound — invariant 4)
  - `workspace://<name>` — the URI itself IS the workspace
  - `system://`, `template://`, `resource://` — `:any`
    (cross-cutting schemes; workspace boundary doesn't apply)

  Returns the 4-field map `Capability.matches?/2` expects:
  `%{kind: atom, behavior: module, instance: %URI{}, workspace_uri: %URI{} | :any}`.
  """
  @spec cap_for_action(module(), atom(), URI.t()) :: %{
          kind: atom(),
          behavior: module(),
          instance: URI.t(),
          workspace_uri: URI.t() | :any
        }
  def cap_for_action(kind_module, action, %URI{} = target_uri)
      when is_atom(kind_module) and is_atom(action) do
    behavior =
      case Ezagent.BehaviorRegistry.lookup(kind_module, action) do
        {:ok, behavior_module} -> behavior_module
        :error -> :unknown
      end

    %{
      kind: kind_module.type_name(),
      behavior: behavior,
      instance: Ezagent.URI.instance(target_uri),
      workspace_uri: workspace_of(target_uri)
    }
  end
end

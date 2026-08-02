defmodule Ezagent.Resource.FsResolver do
  @moduledoc """
  Hardened, registration-only generic `resource://<ws>/<type>/<name>` filesystem
  resolver (Resource-unification SPEC §5.1).

  Generalizes the proven socialware pattern
  (`Ezagent.Socialware.ConfigProjection.assert_workspace_authority!/2`) to all
  tenant-scoped, content-shaped artifact families, behind a single seam.

  ## Why this exists

  Raw `Ezagent.Home.path/1` is the historic front door for on-disk artifacts.
  That is unsafe to expose to URI-addressed callers: an authorable
  `resource://<ws>/<type>/<name>` URI lets a caller name *any* workspace's bytes,
  and `Ezagent.URI.segment!/1` does not reject `.`/`..` traversal. This resolver
  is the hardened replacement: `Ezagent.Home` becomes the *backend*, reached only
  on the success path after the closed allowlist, traversal guard, and per-type
  authority check all pass.

  ## Contract (SPEC §5.1, properties R-1..R-4)

    * **R-1 — closed allowlist (no implicit Home catch-all).** Each `<type>` is
      explicitly `register_type/2`'d. An unregistered `<type>` returns `:none`
      ("not a type this resolver owns") — it NEVER resolves to a Home path.
    * **R-2 — unsafe-segment rejection BEFORE any `Path.join`.** Any `<ws>`,
      `<type>`, or `<name>` equal to `"."`/`".."`, or containing a separator
      (Unix `/` or Windows `\\`) or NUL, returns `{:error, {:unsafe_segment, _}}`
      before the backend is touched.
    * **R-3 — authorization-bearing.** `resolve/2` takes the caller's
      authenticated `scope` and runs the per-`<type>` `authority/2` against it
      BEFORE any backend resolve. There is **no `resolve/1`** that skips authz.
      `scope.workspace` always comes from the caller's authenticated context,
      **never** from the URI being resolved (that would be circular — a forged
      `resource://victim/...` resolved under scope `attacker` fails authority).
    * **R-4 — Home is the backend.** `Ezagent.Home.path/1` is called only on the
      success path, only with the registered `backend_component`.

  ## Immutable-after-boot registry (codex round-1..4 HIGH/CRITICAL)

  The `<type>` allowlist lives in a `:protected` ETS table owned by
  `Ezagent.Resource.FsResolver.Registry` (a GenServer) — the **sole writer**.
  Arbitrary runtime code cannot insert/replace/delete a type spec (which would
  swap an `authority` fn or `backend_component` and subvert the central FS auth
  boundary): non-owner `:ets.insert/2` raises `ArgumentError`.

  Crucially, the allowlist is a **pure function of a compile/config-time
  registration source applied once in `Registry.init/1`** — there is **no
  post-`init` write message** in `:prod` (no add/remove/seal/unseal). This kills
  the entire reopen class the earlier review rounds surfaced (seal-in-state lost
  on restart; seal-in-`:persistent_term` globally erasable; seal re-seeded from a
  mutable app-env key): a Registry crash + supervised restart just re-applies the
  same boot source, so a restart can only reproduce the boot allowlist, never
  reopen it. No externally-mutable flag participates in the security decision.

  Test-only registration (`register_type/2` here → `Registry.register_for_test/2`)
  is compiled out of `:prod`.

  ## P0 is DORMANT

  P0's boot registration source is empty — the resolver infrastructure ships but
  no production caller is migrated. P1 adds the config-dir type; P2 adds uploads
  by extending `Registry.boot_registrations/0`, NOT via any runtime call.
  Tests register via the test-only `register_type/2` path.
  """

  alias Ezagent.URI, as: EzURI

  @table :ezagent_resource_fs_types

  @typedoc """
  The caller's authenticated authorization context.

  `:workspace` is the workspace the caller is acting within (name or URI),
  obtained from the caller's authenticated context — NEVER from the URI being
  resolved.
  """
  @type scope :: %{
          required(:workspace) => String.t() | URI.t(),
          optional(:principal) => URI.t() | nil
        }

  @typedoc """
  A registered `<type>`'s backing spec.

    * `:backend_component` — the `Ezagent.Home` component the bytes live under
      (e.g. `"uploads"`, `"cc-agents"`).
    * `:authority` — the per-type authorization check; receives BOTH the URI and
      the caller's authenticated `scope` and asserts the URI's structural `<ws>`
      segment is authoritative for this caller. A pure `(URI.t() -> _)` is
      insufficient (codex HIGH): a resolver with no caller context cannot tell who
      is asking.
  """
  @type type_spec :: %{
          backend_component: String.t(),
          authority: (URI.t(), scope() -> :ok | {:error, term()})
        }

  if Mix.env() != :prod do
    @doc """
    Register a test-only `<type>`. **Test-only** — compiled out of `:prod`.

    Production types are NOT registered through any runtime call; they live in the
    immutable `Registry.boot_registrations/0` source applied at `init/1`. This
    facade exists only so tests can exercise the resolver against a registered
    type. Raises on a malformed spec.
    """
    @spec register_type(String.t(), type_spec()) :: :ok | {:error, term()}
    def register_type(type, %{backend_component: backend, authority: authority})
        when is_binary(type) and type != "" and is_binary(backend) and backend != "" and
               is_function(authority, 2) do
      Ezagent.Resource.FsResolver.Registry.register_for_test(type, %{
        backend_component: backend,
        authority: authority
      })
    end

    @doc "Remove a test-only `<type>`. **Test-only** — compiled out of `:prod`."
    @spec unregister_type(String.t()) :: :ok
    def unregister_type(type) when is_binary(type),
      do: Ezagent.Resource.FsResolver.Registry.unregister_for_test(type)
  end

  @doc """
  Resolve `resource://<ws>/<type>/<name>` to an on-disk path under the caller's
  authenticated `scope`.

  Returns:

    * `{:ok, path}` — R-1..R-3 passed; `path` is under the registered backend.
    * `:none` — not a `resource://` URI we own (unregistered `<type>`, or a
      non-resource URI).
    * `{:error, {:malformed_resource_uri, _}}` — a structurally-`resource` URI
      missing a `<ws>`/`<type>`/`<name>` segment.
    * `{:error, {:unsafe_segment, _}}` — R-2 traversal/separator/NUL rejection.
    * `{:error, reason}` — the per-type `authority/2` rejected the caller (R-3;
      fail loud, never a silent `:none`).
  """
  @spec resolve(URI.t(), scope()) ::
          {:ok, String.t()} | :none | {:error, term()}
  def resolve(%URI{scheme: "resource"} = uri, %{workspace: _} = scope) do
    with {:ok, ws} <- seg(EzURI.workspace_name(uri), uri),
         {:ok, type} <- seg(EzURI.type(uri), uri),
         {:ok, name} <- seg(EzURI.name(uri), uri) do
      case lookup(type) do
        # R-1: NO Home catch-all — an unregistered type never resolves.
        :none ->
          :none

        {:ok, spec} ->
          with :ok <- reject_unsafe([ws, type, name]),
               :ok <- spec.authority.(uri, scope) do
            # R-4: Home reached only here, only with the registered component.
            {:ok, Path.join([Ezagent.Home.path(spec.backend_component), ws, name])}
          end
      end
    end
  end

  # Not a resource URI — not ours.
  def resolve(%URI{} = _other, %{workspace: _}), do: :none

  # ── internals ──────────────────────────────────────────────────────────────

  defp seg({:ok, v}, _uri), do: {:ok, v}
  defp seg(:error, uri), do: {:error, {:malformed_resource_uri, URI.to_string(uri)}}

  defp lookup(type) do
    case :ets.lookup(table(), type) do
      [{^type, spec}] -> {:ok, spec}
      [] -> :none
    end
  rescue
    ArgumentError ->
      # Table absent means the Registry GenServer has not booted — fail loud
      # rather than silently treating every type as unregistered.
      reraise RuntimeError,
              "Ezagent.Resource.FsResolver.Registry is not running (ETS table absent)",
              __STACKTRACE__
  end

  # R-2 — reject ".", "..", path separators (BOTH Unix "/" and Windows "\\" —
  # codex round-3 HIGH), and NUL in any segment, BEFORE any `Path.join`. Defense
  # in depth on top of `Ezagent.URI.segment!/1`, which does NOT reject `.`/`..`
  # (codex round-1 HIGH gap).
  @separators ["/", "\\"]

  defp reject_unsafe(segments) do
    Enum.reduce_while(segments, :ok, fn s, :ok ->
      if safe_component?(s) do
        {:cont, :ok}
      else
        {:halt, {:error, {:unsafe_segment, s}}}
      end
    end)
  end

  @doc """
  Whether a string is a single safe path component — not `.`/`..`, no path
  separator (`/` or `\\`), no NUL, non-empty.

  Used both for URI segments (R-2) and to validate a registered type's
  `backend_component` at registration time (codex round-5 HIGH) so a boot/test
  registration cannot point a type's backend outside its intended Home component
  (e.g. `"../credentials"`).
  """
  @spec safe_component?(term()) :: boolean()
  def safe_component?(s) when is_binary(s) and s != "" do
    s not in [".", ".."] and not String.contains?(s, @separators) and
      not String.contains?(s, <<0>>)
  end

  def safe_component?(_), do: false

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Authority for per-agent config-dir `<ns>-agents` types (Resource-unification
  P1). Asserts the URI's structural `<ws>` segment equals the caller's
  authenticated `scope.workspace` — the workspace-isolation boundary for the
  per-agent config-home.

  `scope.workspace` is the AUTHENTICATED subject (e.g. derived from the agent URI
  in `Ezagent.Sandbox.ConfigDir.path/2`), NEVER taken from `uri` — so a forged
  `resource://victim/<ns>-agents/x` resolved under scope `acme` fails loud
  (codex CRITICAL: the check is non-tautological precisely because the two `<ws>`
  values come from independent sources).
  """
  @spec config_dir_authority(URI.t(), scope()) :: :ok | {:error, term()}
  def config_dir_authority(%URI{} = uri, %{workspace: scope_ws}) do
    assert_workspace_segment(uri, scope_ws)
  end

  @doc """
  Authority for the per-agent `git-identity` type (SSH 凭据 1b).

  Asserts the URI's structural `<ws>` segment equals the caller's authenticated
  `scope.workspace` — identical logic to `config_dir_authority/2`, but a
  **distinct named function on purpose**.

  Sharing `config_dir_authority/2` here would violate this module's existing
  family invariant (:301-304 below: "families must NOT share one fn reference"
  — `uploads_authority/2` at :291-294 is the same rule's existing precedent).
  The Registry keys config-dir family membership on `authority` IDENTITY
  (`config_dir_type?/1`); today's concrete consequence of violating it is that
  `resolve_config_dir/1`
  (`ezagent_domain_session/.../uri_query_resolvers.ex:136`) would classify
  git-identity as a config-dir resource type and return `{:error,
  :config_dir_resource_requires_scope}`, which `CascadeRuntime.layer_dirs/1`
  treats as a FATAL cascade abort (not "skip this layer") — spawn fails loud.
  Keeping the function distinct is what makes "同部署内两个 agent 是否隔离，
  完全取决于有没有各自发那条 cap" structurally true.
  """
  @spec git_identity_authority(URI.t(), scope()) :: :ok | {:error, term()}
  def git_identity_authority(%URI{} = uri, %{workspace: scope_ws}) do
    assert_workspace_segment(uri, scope_ws)
  end

  @doc """
  Builds FsResolver resource-type declarations for per-agent config-dir template
  classes.

  Plugins own the declaration source (`resource_types/0`) and call this helper
  with their config-dir-backed template classes. The resulting type name and
  backend component are both `<config_dir_namespace>-agents`, guarded by
  `config_dir_authority/2`.
  """
  @spec config_dir_resource_types([module()]) :: [{String.t(), type_spec()}]
  def config_dir_resource_types(template_classes) when is_list(template_classes) do
    Enum.map(template_classes, fn template_class ->
      namespace = template_class.config_dir_namespace()
      type = "#{namespace}-agents"

      {type,
       %{
         backend_component: type,
         authority: &__MODULE__.config_dir_authority/2
       }}
    end)
  end

  @doc """
  Authority for the `uploads` type (Resource-unification P2b). Asserts the URI's
  structural `<ws>` segment equals the caller's authenticated `scope.workspace` —
  the workspace-isolation boundary for chat-attachment downloads.

  This is the structural replacement for the participation-based
  `EzagentWeb.UploadsController` `caller_in_attaching_messages?/2` check: a
  download is authorized iff the request-mount workspace matches the upload's
  `<ws>` segment. `scope.workspace` is the AUTHENTICATED subject (the
  controller/LiveView mount), NEVER taken from `uri` — so a signed token bound to
  `resource://victim/uploads/f` cannot be served to a caller mounted in workspace
  `acme` (the check is non-tautological because the two `<ws>` values come from
  independent sources: the signed token vs. the authenticated mount).

  A distinct named fn from `config_dir_authority/2` so the registry — which keys
  family membership on `authority` IDENTITY (`config_dir_type?/1`) — never claims
  uploads as a config-dir layer.
  """
  @spec uploads_authority(URI.t(), scope()) :: :ok | {:error, term()}
  def uploads_authority(%URI{} = uri, %{workspace: scope_ws}) do
    assert_workspace_segment(uri, scope_ws)
  end

  # Shared `uri.<ws> == scope.workspace` workspace-isolation check used by every
  # per-tenant type's authority/2. Private so each type keeps its OWN named
  # authority fn (the registry keys behaviour on authority identity, so families
  # must NOT share one fn reference).
  defp assert_workspace_segment(%URI{} = uri, scope_ws) do
    with {:ok, uri_ws} <- EzURI.workspace_name(uri),
         {:ok, scope_ws_name} <- workspace_name_of(scope_ws) do
      if uri_ws == scope_ws_name do
        :ok
      else
        {:error, {:foreign_workspace, %{uri: uri_ws, scope: scope_ws_name}}}
      end
    else
      :error -> {:error, {:malformed_resource_uri, URI.to_string(uri)}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Whether `type` is a registered per-agent config-dir family type (one of the
  `<ns>-agents` types whose `authority/2` is `config_dir_authority/2`).

  The `:config_dir` UriQuery owner uses this to scope its fail-loud /
  scoped-resolve behavior to the config-dir family ONLY (Resource-unification P1,
  codex round-5 HIGH): a bare `resource://` URI of a config-dir type must fail
  loud (`:config_dir_resource_requires_scope`, no tautological self-scope), but a
  bare `resource://` URI of ANY OTHER resource family (e.g. a future
  `resource://<ws>/uploads/<f>` layer) is **not** this attribute's concern and
  must fall through to `:none` so the credential cascade skips it as a
  not-a-config-dir layer — exactly as it did pre-P1 (when the socialware resolver
  returned `:none` for non-socialware types). Membership is keyed on the
  registered `authority` identity, NOT a `<type>` string suffix, so it cannot
  accidentally claim a future non-config type whose name happens to end in
  `-agents`.
  """
  @spec config_dir_type?(String.t()) :: boolean()
  def config_dir_type?(type) when is_binary(type) do
    case lookup(type) do
      {:ok, %{authority: authority}} -> authority == (&__MODULE__.config_dir_authority/2)
      :none -> false
    end
  end

  def config_dir_type?(_), do: false

  # scope.workspace may be a plain workspace-name string OR a workspace URI; both
  # normalize to the name for comparison against the URI's `<ws>` segment.
  defp workspace_name_of(ws) when is_binary(ws) and ws != "", do: {:ok, ws}

  defp workspace_name_of(%URI{} = ws_uri) do
    case EzURI.workspace_name(ws_uri) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:malformed_scope_workspace, URI.to_string(ws_uri)}}
    end
  end

  defp workspace_name_of(other), do: {:error, {:malformed_scope_workspace, other}}
end

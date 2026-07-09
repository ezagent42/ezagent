defmodule Ezagent.System.FsResolver do
  @moduledoc """
  Hardened `system://<type>[/<name>]` filesystem resolution seam
  (Resource-unification P3 / SPEC §10 OI-3 — "system artifacts go through
  `UriQuery` via `system://`").

  ## Why this exists (and how it differs from the tenant resolver)

  `Ezagent.Resource.FsResolver` addresses *tenant-scoped, content-shaped*
  artifacts behind `resource://<ws>/<type>/<name>` with a per-`<type>` authority
  check (the caller's authenticated `<ws>` must equal the URI's `<ws>`).

  System artifacts are different: a global app credential, a plugin config file,
  a per-deployment diagnostic log directory belong to the **node/deployment**,
  not to a tenant. They have **no natural `<ws>`** and **no per-caller authority
  axis** — every component of the running node may read the deployment's own
  feishu cred. OI-3 (DECIDED 2026-06-07) is explicit that "no natural `<ws>`" is
  NOT an exemption: such callers still route through `UriQuery`, just via the
  already-allowlisted `system://` scheme instead of `resource://`.

  This module is that seam: a CLOSED `<type>` allowlist mapping each system type
  to a sanctioned `Ezagent.Home` component, with the SAME byte-path hardening as
  the tenant resolver (`.`/`..`/separator/NUL rejection BEFORE any `Path.join`,
  no implicit Home catch-all, a single `Home.path/1` chokepoint reached only on
  the success path).

  ## Contract

    * **R-1 — closed allowlist.** An unregistered `<type>` returns `:none`
      (not a system artifact this seam owns) — it NEVER resolves to a Home path.
      A non-`system://` URI is also `:none`.
    * **R-2 — unsafe-segment rejection.** The `<type>` and (optional) `<name>`
      are rejected (`{:error, {:unsafe_segment, _}}`) if equal to `"."`/`".."`,
      or containing a path separator or NUL, BEFORE the backend is touched.
      (`Ezagent.URI.segment!/1` permits `.`/`..`/NUL — codex round-1 HIGH gap.)
    * **R-3 — no authority axis.** System artifacts are node-global; there is no
      `scope` argument and no per-caller authority. (A `system://` URI is itself
      a member of the closed cross-cutting scheme allowlist — invariant #11.)
    * **R-4 — Home is the backend.** `Ezagent.Home.path/1` is called only on the
      success path, only with the registered component for the matched `<type>`.

  ## The `<type>` catalog

  Each `<type>` names a sanctioned `Ezagent.Home` component (NOT an arbitrary
  path). The catalog is compile-time and closed — adding a system artifact family
  is a deliberate edit here, never a runtime registration:

    * `credentials` → `Home.path(:credentials)` — global app creds (feishu app
      cred, smtp_config, the cc-bridge token registry).
    * `logs`        → `Home.path(:logs)` — per-deployment diagnostic logs.
    * `plugins`     → `Home.path(:plugins)` — plugin config files.
    * `inbox`       → `Home.path("inbox")` — the profile-level inbox tree.
    * `socialware`  → `Home.path("socialware")` — deployment-level socialware
      manifest seeds, swept by the late boot lane
      (`Ezagent.Socialware.ManifestSeed.scan_all!/1`).
    * `skills`      → `Home.path("skills")` — deployment-level skill seed
      materialization, swept by `Ezagent.Home.SkillSeed`.
  """

  alias Ezagent.URI, as: EzURI

  @attr :system_path

  # Closed `<type>` → Home component allowlist (R-1). Each value is a single
  # sanctioned Home component; the resolver's only `Home.path/1` call (R-4) uses
  # exactly this value, so a `<type>` can never name a path outside its component.
  @catalog %{
    "credentials" => :credentials,
    "logs" => :logs,
    "plugins" => :plugins,
    "inbox" => "inbox",
    "socialware" => "socialware",
    "skills" => "skills"
  }

  @separators ["/", "\\"]

  @doc "The `Ezagent.UriQuery` attribute this seam owns."
  @spec attr() :: atom()
  def attr, do: @attr

  @doc """
  Idempotently register the `system://` resolution seam with `Ezagent.UriQuery`.

  System resolution is global + stateless, so registration is a plain UriQuery
  attr (no `:protected` ETS registry — there is no per-`<type>` authority fn to
  protect, only the compile-time `@catalog`).
  """
  @spec register() :: :ok | {:error, term()}
  def register do
    case Ezagent.UriQuery.register(@attr, &__MODULE__.resolve/1) do
      :ok -> :ok
      {:error, {:already_registered, @attr}} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Resolve a `system://<type>[/<name>]` URI to its on-disk path.

  Returns:

    * `{:ok, path}` — R-1/R-2 passed; `path` is under the registered component.
    * `:none` — not a `system://` URI we own (unregistered `<type>`, or a
      non-system URI).
    * `{:error, {:unsafe_segment, _}}` — R-2 traversal/separator/NUL rejection.
  """
  @spec resolve(term()) :: {:ok, String.t()} | :none | {:error, term()}
  def resolve(%URI{scheme: "system"} = uri) do
    # `Ezagent.URI.type/1` reads the system type-axis segment (the `<type>` in
    # `system://<type>[/<name>]`); accessor use keeps positional `%URI{host:}`
    # reads centralised in `Ezagent.URI` (uri_query.scan `positional_uri_read`).
    case EzURI.type(uri) do
      {:ok, type} ->
        case Map.fetch(@catalog, type) do
          # R-1: NO Home catch-all — an unregistered system type never resolves.
          :error ->
            :none

          {:ok, component} ->
            names = name_segments(uri)

            with :ok <- reject_unsafe([type | names]) do
              # R-4: Home reached only here, only with the catalog's component.
              {:ok, Path.join([Ezagent.Home.path(component) | names])}
            end
        end

      :error ->
        :none
    end
  end

  # Not a system URI — not ours.
  def resolve(%URI{}), do: :none
  def resolve(_other), do: :none

  @doc """
  Resolve `arg` through `Ezagent.UriQuery` (registering the seam first if
  needed), returning the path or raising. The runtime callers' entry point.
  """
  @spec path!(URI.t()) :: String.t()
  def path!(%URI{} = uri) do
    :ok = register()

    case Ezagent.UriQuery.resolve(@attr, uri) do
      {:ok, path} when is_binary(path) ->
        path

      :none ->
        raise ArgumentError, "not a registered system artifact: #{URI.to_string(uri)}"

      {:error, reason} ->
        raise ArgumentError, "could not resolve system path: #{inspect(reason)}"
    end
  end

  @doc """
  Read + parse a YAML system artifact addressed by `uri`, through the seam.

  Resolves `uri` via `path!/1` (so the artifact access goes through `UriQuery` /
  the hardened `system://` resolver, NOT raw `Ezagent.Home`), then reads and
  YAML-parses it. Returns the same shape as the legacy
  `Ezagent.Home.read_credentials/1`:

    * `{:ok, map}` — file present + parsed;
    * `{:error, :not_found}` — file absent (a normal startup state);
    * `{:error, reason}` — read/parse failure.

  This is the seam-backed reader migrated callers use instead of
  `Ezagent.Home.read_credentials/1`, so the *operational* artifact access — not
  just an operator-facing log string — flows through the `system://` seam
  (Resource-unification SPEC §10 OI-3).
  """
  @spec read_yaml(URI.t()) :: {:ok, term()} | {:error, :not_found} | {:error, term()}
  def read_yaml(%URI{} = uri) do
    case File.read(path!(uri)) do
      {:ok, body} -> YamlElixir.read_from_string(body)
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # The `<name>` segment of a `system://<type>/<name>` URI as a single-element
  # list, or `[]` for the single-segment `system://<type>` shape. Uses
  # `Ezagent.URI.name/1` (which returns `:error` for the 1-segment shape) so the
  # positional path read stays centralised in `Ezagent.URI`.
  defp name_segments(%URI{} = uri) do
    case EzURI.name(uri) do
      {:ok, name} -> [name]
      :error -> []
    end
  end

  # R-2 — reject ".", "..", path separators (Unix "/" and Windows "\\"), and NUL
  # in any segment, BEFORE any `Path.join`. Defense in depth over
  # `Ezagent.URI.segment!/1`, which does NOT reject `.`/`..`/NUL.
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
  """
  @spec safe_component?(term()) :: boolean()
  def safe_component?(s) when is_binary(s) and s != "" do
    s not in [".", ".."] and not String.contains?(s, @separators) and
      not String.contains?(s, <<0>>)
  end

  def safe_component?(_), do: false
end

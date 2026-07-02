defmodule Ezagent.Socialware.ConfigProjection do
  @moduledoc """
  #607 — the CONSUME half of P6 self-evolve (spec §7 steps 4–5).

  PR #606 wrote immutable config objects + a pointer but nothing read them. This
  module is the seam that lets the #17 credential/config cascade MATERIALIZE a
  socialware config OBJECT:

    1. `object_uri/2` gives an immutable `ConfigObject` a **stable resolvable
       URI** in the `resource://` scheme (one of the six allowed schemes —
       invariant #11; a `config://` scheme would be rejected by
       `Ezagent.URI.new!/1`). The URI keys a SPECIFIC immutable object by its id,
       NOT the mutable pointer.

       Object-keyed (not pointer-keyed) is what makes `apply_delta` naturally
       ATOMIC (spec §7.4: "repoints the agent's #17 high cascade layer at it" —
       *it* being the new immutable config object). Because the agent's cascade
       layer URI names a specific immutable object, the steps order so that no
       single-step failure leaves harmful uncompensated state (see
       `Ezagent.ActionSet.ConfigUpdate.handle_apply_delta/2`). The object is
       immutable, so `resolve_config_dir/1` can never observe a stale or
       half-written body — there is no read/write race.

    2. `resolve_config_dir/1` is registered under the `:socialware_config_dir`
       `Ezagent.UriQuery` attribute (socialware owns it — no dependency cycle).
       The single `:config_dir` owner (`EzagentDomainInstanceMessage`) delegates
       the `resource://<ws>/socialware-config-object/...` shape here at runtime
       via the ETS `UriQuery` table, so both the create-path
       (`Ezagent.Entity.Agent`) and the respawn-path
       (`Ezagent.Credential.CascadeRuntime`) pick it up with no edit to the
       resolver, materializer, or cascade core (Approach A).

    3. The body→config-files projection is **scoped to soul** for now (spec §5.5):
       the config object's `body` is written into a transient on-disk config dir's
       `CLAUDE.md` — the file a cc agent reads its soul/system-prompt from (see
       `Ezagent.Template.CcAgent`). Skill/KB projection is a documented follow-up.
  """

  alias Ezagent.Socialware.ConfigStore

  @type_segment "socialware-config-object"
  @soul_file "CLAUDE.md"

  @doc """
  The `Ezagent.UriQuery` attribute this module owns.

  Distinct from the single `:config_dir` owner so registering it introduces no
  cross-domain dependency cycle; `:config_dir` delegates here at runtime.
  """
  @spec attr() :: atom()
  def attr, do: :socialware_config_dir

  @doc "The `resource://` type segment that marks a socialware config OBJECT URI."
  @spec type_segment() :: String.t()
  def type_segment, do: @type_segment

  @doc "Register the `:socialware_config_dir` UriQuery resolver (idempotent-friendly)."
  @spec register() :: :ok | {:error, term()}
  def register do
    case Ezagent.UriQuery.register(attr(), &__MODULE__.resolve_config_dir/1) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Build the stable resolvable `resource://` URI for an IMMUTABLE config object.

  The object's id (a UUID) is Base64url-encoded (no padding — keeps the name
  segment URI-path-safe) into the `<name>` position. The `<workspace>` structural
  segment is taken from the owning `workspace_uri` and is the cap-checked
  authority (`Ezagent.URI.workspace_of/1` / WorkspaceRegistry scope the URI by
  it); `resolve_config_dir/1` re-asserts it against the loaded object's own
  `workspace_uri` so a forged URI cannot resolve another tenant's object.
  """
  @spec object_uri(URI.t() | String.t(), String.t()) :: URI.t()
  def object_uri(workspace_uri, object_id) when is_binary(object_id) and object_id != "" do
    workspace = uri_string!(workspace_uri)
    name = Base.url_encode64(object_id, padding: false)

    workspace_name =
      case Ezagent.URI.workspace_name(Ezagent.URI.new!(workspace)) do
        {:ok, ws_name} -> ws_name
        :error -> raise ArgumentError, "config object workspace has no name: #{workspace}"
      end

    Ezagent.URI.resource(workspace_name, @type_segment, name)
  end

  @doc """
  Recover the immutable config object's `id` a `object_uri/2` encodes.

  Returns `{:ok, object_id}` for a socialware-config-object resource URI,
  `:error` otherwise (e.g. a different `resource://` type — "not mine").
  """
  @spec object_id_from_uri(URI.t()) :: {:ok, String.t()} | :error
  def object_id_from_uri(%URI{scheme: "resource"} = uri) do
    with {:ok, @type_segment} <- Ezagent.URI.type(uri),
         {:ok, name} <- Ezagent.URI.name(uri),
         {:ok, object_id} <- Base.url_decode64(name, padding: false) do
      {:ok, object_id}
    else
      _ -> :error
    end
  end

  def object_id_from_uri(_), do: :error

  @doc """
  `:socialware_config_dir` resolver — materialize the IMMUTABLE config object
  named by `uri` into a transient config dir and return its path.

    * `{:ok, dir}` — a transient dir holding the projected soul file.
    * `:none` — the URI is not a socialware-config-object URI (the layer simply
      contributes nothing).
    * `{:error, reason}` — projection failed (fail loud; never a silent default).

  ## Workspace-segment authority (#607 codex MEDIUM)

  The object id alone is not authoritative: the `resource://` URI is authorable,
  so a caller could mint `resource://A/socialware-config-object/<id-of-B's-object>`
  and resolve tenant B's object from inside A's structural workspace. The outer
  URI's structural `<workspace>` segment is the cap-checked authority, so it MUST
  agree with the LOADED object's own `workspace_uri`. A mismatch is a forged URI —
  raise LOUDLY (let-it-crash; never a silent `:none` that would be swallowed as
  "not mine").
  """
  @spec resolve_config_dir(term()) :: Ezagent.UriQuery.result()
  def resolve_config_dir(%URI{} = uri) do
    case object_id_from_uri(uri) do
      {:ok, object_id} ->
        case ConfigStore.fetch_object(object_id) do
          {:ok, object} ->
            :ok = assert_workspace_authority!(uri, object)
            project_body(object.body)

          :none ->
            # The id decoded to a socialware-config-object shape but no such
            # object exists. The URI is well-formed and ours, but points at a
            # non-existent immutable object — a programmer/data error (an object
            # URI is only ever minted for an object that was just written), so
            # fail loud rather than silently contribute nothing.
            {:error, {:socialware_config_object_not_found, object_id}}
        end

      :error ->
        :none
    end
  end

  def resolve_config_dir(_), do: :none

  # The structural `<workspace>` segment of the outer resource URI is the
  # cap-checked authority; the loaded object's own `workspace_uri` must derive
  # the SAME workspace name. A divergence means the URI was forged to read
  # another tenant's object — fail loud (#607 codex MEDIUM).
  defp assert_workspace_authority!(%URI{} = uri, object) do
    structural =
      case Ezagent.URI.workspace_name(uri) do
        {:ok, name} ->
          name

        :error ->
          raise ArgumentError,
                "socialware config object URI has no workspace segment: #{URI.to_string(uri)}"
      end

    object_ws =
      case Ezagent.URI.workspace_name(Ezagent.URI.new!(object.workspace_uri)) do
        {:ok, name} ->
          name

        :error ->
          raise ArgumentError,
                "socialware config object has no workspace: #{object.workspace_uri}"
      end

    if structural == object_ws do
      :ok
    else
      raise ArgumentError,
            "socialware config object workspace mismatch: structural segment " <>
              "#{inspect(structural)} (#{URI.to_string(uri)}) != object workspace " <>
              "#{inspect(object_ws)} (#{object.workspace_uri}) — cross-tenant boundary violation"
    end
  end

  # ── body → soul projection (spec §5.5, scoped to soul) ─────────────────────

  defp project_body(body) when is_map(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "socialware-config-#{System.unique_integer([:positive])}"
      )

    soul = render_soul(body)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, @soul_file), soul) do
      {:ok, dir}
    else
      {:error, reason} -> {:error, {:socialware_config_projection_failed, reason}}
    end
  end

  defp project_body(other), do: {:error, {:socialware_config_invalid_body, other}}

  @doc """
  Render a config-object `body` into the cc soul/system-prompt (`CLAUDE.md`) text.

  Deterministic (keys sorted) so two materializations of the same object yield
  byte-identical files — required for the atomic-replace no-op + rollback
  determinism. Public so tests can assert the exact projection.
  """
  @spec render_soul(map()) :: String.t()
  # An autoservice cinnox soul is one authored markdown document; emit it
  # verbatim as CLAUDE.md. (autoservice migration DD3) The key:value clause
  # below stays as the fallback for self-evolve config bodies without a soul_md.
  def render_soul(%{"soul_md" => soul_md}) when is_binary(soul_md), do: soul_md

  def render_soul(body) when is_map(body) do
    lines =
      body
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> "- #{k}: #{render_value(v)}" end)

    """
    # Agent soul (socialware self-evolve config)

    #{Enum.join(lines, "\n")}
    """
  end

  defp render_value(v) when is_binary(v), do: v
  defp render_value(v), do: inspect(v)

  # ── helpers ────────────────────────────────────────────────────────────────

  defp uri_string!(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string!(uri) when is_binary(uri) and uri != "", do: uri
end

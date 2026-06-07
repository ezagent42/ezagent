defmodule Ezagent.Socialware.ConfigProjection do
  @moduledoc """
  #607 — the CONSUME half of P6 self-evolve (spec §7 steps 4–5).

  PR #606 wrote immutable config objects + a pointer but nothing read them. This
  module is the seam that lets the #17 credential/config cascade MATERIALIZE a
  socialware config pointer:

    1. `pointer_uri/4` gives a `ConfigPointer` a **stable resolvable URI** in the
       `resource://` scheme (one of the six allowed schemes — invariant #11; a
       `config://` scheme would be rejected by `Ezagent.URI.new!/1`). The URI keys
       the *pointer*, not a specific object, so it always resolves to the CURRENT
       pointed-at object — that is what makes "re-materialize on next spawn" and
       deterministic rollback work without any version-diffing.

    2. `resolve_config_dir/1` is registered under the `:socialware_config_dir`
       `Ezagent.UriQuery` attribute (socialware owns it — no dependency cycle).
       The single `:config_dir` owner (`EzagentDomainInstanceMessage`) delegates
       the `resource://<ws>/socialware-config/...` shape here at runtime via the
       ETS `UriQuery` table, so both the create-path
       (`Ezagent.Entity.Agent`) and the respawn-path
       (`Ezagent.Credential.CascadeRuntime`) pick it up with no edit to the
       resolver, materializer, or cascade core (Approach A).

    3. The body→config-files projection is **scoped to soul** for now (spec §5.5):
       the config object's `body` is written into a transient on-disk config dir's
       `CLAUDE.md` — the file a cc agent reads its soul/system-prompt from (see
       `Ezagent.Template.CcAgent`). Skill/KB projection is a documented follow-up.
  """

  alias Ezagent.Socialware.{ConfigPointer, ConfigStore}

  @type_segment "socialware-config"
  @soul_file "CLAUDE.md"

  @typedoc "The four parts that key a ConfigPointer."
  @type pointer_key ::
          {layer :: String.t(), workspace :: String.t(), subject :: String.t(), key :: String.t()}

  @doc """
  The `Ezagent.UriQuery` attribute this module owns.

  Distinct from the single `:config_dir` owner so registering it introduces no
  cross-domain dependency cycle; `:config_dir` delegates here at runtime.
  """
  @spec attr() :: atom()
  def attr, do: :socialware_config_dir

  @doc "The `resource://` type segment that marks a socialware config pointer URI."
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
  Build the stable resolvable `resource://` URI for a config pointer.

  The pointer's composite id (`layer|workspace|subject|key`) is Base64url-encoded
  (no padding — keeps the name segment URI-path-safe) into the `<name>` position.
  """
  @spec pointer_uri(
          atom() | String.t(),
          URI.t() | String.t(),
          URI.t() | String.t(),
          String.t()
        ) :: URI.t()
  def pointer_uri(layer, workspace_uri, subject_uri, key) do
    layer = normalize_layer!(layer)
    workspace = uri_string!(workspace_uri)
    subject = uri_string!(subject_uri)

    pointer_id = ConfigPointer.id(layer, workspace, subject, key)
    name = Base.url_encode64(pointer_id, padding: false)

    workspace_name =
      case Ezagent.URI.name(Ezagent.URI.new!(workspace)) do
        {:ok, ws_name} -> ws_name
        :error -> raise ArgumentError, "config pointer workspace has no name: #{workspace}"
      end

    Ezagent.URI.resource(workspace_name, @type_segment, name)
  end

  @doc """
  Recover the `{layer, workspace, subject, key}` a `pointer_uri/4` encodes.

  Returns `{:ok, key}` for a socialware-config resource URI, `:error` otherwise.

  ## Workspace-segment authority (#607 codex MEDIUM)

  The `<workspace>` encoded in the base64 payload is NOT authoritative on its
  own — the `resource://` URI is authorable, so a caller could mint a URI whose
  STRUCTURAL `<workspace>` segment is tenant A while the payload encodes tenant
  B, and resolve B's pointer from inside A (a cross-tenant boundary hole). The
  outer URI's structural workspace segment is the cap-checked authority (it is
  what `Ezagent.URI.workspace_of/1` / WorkspaceRegistry scope the URI by), so it
  MUST agree with the decoded workspace. A mismatch is a forged URI — raise
  LOUDLY (let-it-crash; never a silent `:error` that would be swallowed as
  "not mine" by `resolve_config_dir/1`).
  """
  @spec pointer_key_from_uri(URI.t()) :: {:ok, pointer_key()} | :error
  def pointer_key_from_uri(%URI{scheme: "resource"} = uri) do
    with {:ok, @type_segment} <- Ezagent.URI.type(uri),
         {:ok, name} <- Ezagent.URI.name(uri),
         {:ok, decoded} <- Base.url_decode64(name, padding: false),
         [layer, workspace, subject, key] <- String.split(decoded, "|", parts: 4) do
      :ok = assert_workspace_authority!(uri, workspace)
      {:ok, {layer, workspace, subject, key}}
    else
      _ -> :error
    end
  end

  def pointer_key_from_uri(_), do: :error

  # The structural `<workspace>` segment of the outer resource URI is the
  # cap-checked authority; the decoded payload's `workspace` must derive the
  # SAME workspace name. A divergence means the URI was forged to read another
  # tenant's pointer — fail loud (#607 codex MEDIUM).
  defp assert_workspace_authority!(%URI{} = uri, encoded_workspace) do
    structural =
      case Ezagent.URI.workspace_name(uri) do
        {:ok, name} ->
          name

        :error ->
          raise ArgumentError,
                "socialware config pointer URI has no workspace segment: #{URI.to_string(uri)}"
      end

    encoded =
      case Ezagent.URI.workspace_name(Ezagent.URI.new!(encoded_workspace)) do
        {:ok, name} ->
          name

        :error ->
          raise ArgumentError,
                "socialware config pointer payload has no workspace: #{encoded_workspace}"
      end

    if structural == encoded do
      :ok
    else
      raise ArgumentError,
            "socialware config pointer workspace mismatch: structural segment " <>
              "#{inspect(structural)} (#{URI.to_string(uri)}) != encoded workspace " <>
              "#{inspect(encoded)} (#{encoded_workspace}) — cross-tenant boundary violation"
    end
  end

  @doc """
  `:socialware_config_dir` resolver — materialize the CURRENT pointed-at config
  object's `body` into a transient config dir and return its path.

    * `{:ok, dir}` — a transient dir holding the projected soul file.
    * `:none` — the URI is not a socialware-config pointer, or no object is
      pointed yet (the layer simply contributes nothing).
    * `{:error, reason}` — projection failed (fail loud; never a silent default).
  """
  @spec resolve_config_dir(term()) :: Ezagent.UriQuery.result()
  def resolve_config_dir(%URI{} = uri) do
    case pointer_key_from_uri(uri) do
      {:ok, {layer, workspace, subject, key}} ->
        case ConfigStore.resolve(layer, workspace, subject, key) do
          {:ok, object} -> project_body(object.body)
          :none -> :none
        end

      :error ->
        :none
    end
  end

  def resolve_config_dir(_), do: :none

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

  defp normalize_layer!(layer) when is_atom(layer), do: Atom.to_string(layer)
  defp normalize_layer!(layer) when is_binary(layer) and layer != "", do: layer

  defp uri_string!(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string!(uri) when is_binary(uri) and uri != "", do: uri
end

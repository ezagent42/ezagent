defmodule Ezagent.ActionSet.Kb do
  @moduledoc """
  KB Behavior — the thin framework half of the retrieval-first KB (SPEC rev 3).

  `use Ezagent.Lifecycle` + `action/3` + `create/1` + `activate/2` +
  `handle_<action>/2`. Two cap-distinct actions:

    * `:query` (cap subject `{Behavior.Kb, :query}`) — READ. FTS5 `MATCH` →
      top-k ranked chunks with provenance (SPEC §5.4).
    * `:ingest` (cap subject `{Behavior.Kb, :ingest}`) — WRITE. Resolve a
      `resource://<ws>/kb-source/<name>` (FsResolver, cap-gated, symlink-guarded)
      → chunk → REPLACE that source's rows in the per-KB sqlite file.

  Two caps so CapBAC gates ingest vs query at the dispatch layer — a query-only
  consumer can NEVER mutate the corpus (the one security property that must hold
  even at MVP). The cap `kind` axis is `:any` (like kanban): the behavior mounts
  per-instance on the generic `Entity.Agent` host (kind `:agent`), and runtime
  substitutes the host's type_name; hard-writing `:kb`/a kind would make the
  role × native held cap (`:agent`) reject.

  ## Store lifecycle — the sqlite connection is a TRANSIENT

  The corpus is the SEPARATE per-KB sqlite file (`EzagentPluginKb.Store`), NOT
  the agent snapshot. `activate/2` opens it as a transient (two-container
  Lifecycle): the file path is derived from the kb-agent's OWN identity
  (`ctx.self_uri` → `resource://<ws>/kb-store/<agent>` → FsResolver →
  `<Home>/kb-stores/<ws>/<agent>/` + `kb.sqlite`), never from caller input
  (store-path confinement, SPEC §8.5). On every start the connection is rebuilt
  from the file — sqlite IS the disk, so there is no "reopen the index" hole.
  The snapshot persists only lightweight metadata (the store URI + `last_*`).

  ## passive

  The `kb` role is `passive: true` (RF-6): a data actor, not a chat principal —
  reachable only via `kb.*` dispatch + the MCP tool.
  """

  use Ezagent.Lifecycle

  alias Ezagent.ActionSet.Kb.Chunker
  alias Ezagent.Resource.FsResolver
  alias EzagentPluginKb.Store

  # ── actions ─────────────────────────────────────────────────────────────

  action(:query,
    args: %{query: :string, k: :integer},
    returns: %{hits: {:list, :map}},
    caps: [:query],
    modes: [:call],
    description: "search the knowledge base — FTS5 MATCH, top-k ranked chunks with provenance"
  )

  action(:ingest,
    args: %{source_uri: :string},
    returns: %{chunks: :integer},
    caps: [:ingest],
    modes: [:call],
    description: "ingest one source document into the knowledge base (create or overwrite)"
  )

  # ── caps ────────────────────────────────────────────────────────────────

  @doc false
  def required_caps do
    %{
      query: Ezagent.Capability.cap(:any, __MODULE__, :query),
      ingest: Ezagent.Capability.cap(:any, __MODULE__, :ingest)
    }
  end

  # Per-instance owner authority follows the canonical agent resolver:
  # creator_uri -> AgentLineage -> :no_owner. Composition minting therefore
  # stays owner-gated for a concrete KB data-agent.
  @doc false
  def data_owner(instance), do: Ezagent.ActionSet.ApiKeys.data_owner(instance)

  # ── lifecycle ─────────────────────────────────────────────────────────────

  @impl Ezagent.Lifecycle
  def create(_args) do
    # Snapshot holds ONLY lightweight metadata — never the corpus.
    {:ok, %{store_uri: nil, default_k: 5, last_ingest_at: nil, last_query_at: nil}}
  end

  @impl Ezagent.Lifecycle
  def activate(state, ctx) do
    self_uri = Map.fetch!(ctx, :self_uri)

    case open_store(self_uri) do
      {:ok, db, store_uri} ->
        # Reconcile the (durable) store URI for observability; the connection
        # lives ONLY as a transient (never persisted — rebuilt every start).
        {:ok, %{db: db}, %{state | store_uri: store_uri}}

      {:error, reason} ->
        # Let it crash on a genuinely broken store path — the agent cannot
        # serve KB actions without its file.
        {:error, {:kb_store_open_failed, reason}}
    end
  end

  @impl Ezagent.Lifecycle
  def deactivate(_reason, ctx) do
    # Close the transient handle on graceful stop (idempotent on nil).
    Store.close(transient_db(ctx))
    :ok
  end

  # ── handlers ───────────────────────────────────────────────────────────────

  @doc false
  def handle_query(args, ctx) do
    db = transient_db(ctx)
    query = Map.fetch!(args, :query)
    k = positive_k(Map.get(args, :k), ctx)

    case Store.query(db, query, k) do
      {:ok, hits} ->
        {:ok, %{hits: hits}, [{:set, :last_query_at, now()}]}

      {:error, reason} ->
        {:error, {:kb_query_failed, reason}}
    end
  end

  @doc false
  def handle_ingest(args, ctx) do
    db = transient_db(ctx)
    source_uri = Map.fetch!(args, :source_uri)

    with {:ok, path} <- resolve_source(source_uri, ctx),
         {:ok, bytes} <- read_source(path),
         chunks = Chunker.chunk(bytes),
         {:ok, n} <- Store.ingest(db, source_uri, chunks) do
      {:ok, %{chunks: n}, [{:set, :last_ingest_at, now()}]}
    end
  end

  # ── store path (derived from the agent's OWN identity, never caller) ────────

  defp open_store(self_uri) do
    with {:ok, store_uri} <- store_uri_for(self_uri),
         {:ok, dir} <- resolve_store_dir(store_uri, self_uri),
         path = Path.join(dir, "kb.sqlite"),
         {:ok, db} <- Store.open(path) do
      {:ok, db, store_uri}
    end
  end

  # `resource://<ws>/kb-store/<agent>` — `<ws>` + `<agent>` taken from the
  # kb-agent's OWN URI, so a caller can never name a different store (SPEC §8.5).
  defp store_uri_for(self_uri) do
    with {:ok, ws} <- Ezagent.URI.workspace_name(self_uri),
         {:ok, agent} <- Ezagent.URI.name(self_uri) do
      # Typed builder (NOT a raw `resource://` string — the UriQuery scan gate).
      {:ok, Ezagent.URI.resource(ws, "kb-store", agent)}
    else
      _ -> {:error, {:bad_self_uri, URI.to_string(self_uri)}}
    end
  end

  # FsResolver resolves to the per-KB DIRECTORY (R-2 forbids `/` in a segment,
  # so `<name>` cannot itself be `<agent>/kb.sqlite`); the Behavior appends
  # `kb.sqlite`. Scope = the agent's OWN workspace (authority R-3 passes for the
  # agent's own store; a foreign workspace would be rejected).
  defp resolve_store_dir(store_uri, self_uri) do
    with {:ok, ws} <- Ezagent.URI.workspace_name(self_uri) do
      case FsResolver.resolve(store_uri, %{workspace: ws}) do
        {:ok, dir} -> {:ok, dir}
        :none -> {:error, {:unregistered_kb_store_type, URI.to_string(store_uri)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ── source read (FsResolver auth + symlink guard, SPEC §6.2) ────────────────

  defp resolve_source(source_uri_str, ctx) do
    self_uri = Map.fetch!(ctx, :self_uri)

    with {:ok, source_uri} <- parse_uri(source_uri_str),
         {:ok, ws} <- Ezagent.URI.workspace_name(self_uri) do
      # Scope from the kb-agent's authenticated context (its own workspace),
      # NEVER from the URI — R-3. A foreign-workspace source URI is rejected.
      case FsResolver.resolve(source_uri, %{workspace: ws}) do
        {:ok, path} -> reject_symlink_escape(path)
        :none -> {:error, {:unregistered_kb_source_type, source_uri_str}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # R-2 in FsResolver rejects `..` in URI segments before backend touch; this
  # additionally rejects a SYMLINK whose realpath escapes the resolved path
  # (SPEC §6.2: "the read realpath-checks the resolved file").
  defp reject_symlink_escape(path) do
    case File.read_link(path) do
      {:ok, _target} -> {:error, {:symlink_rejected, path}}
      {:error, :einval} -> {:ok, path}
      {:error, :enoent} -> {:error, {:source_not_found, path}}
      {:error, reason} -> {:error, {:source_unreadable, reason}}
    end
  end

  defp read_source(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:source_read_failed, reason}}
    end
  end

  defp parse_uri(str) when is_binary(str) do
    {:ok, Ezagent.URI.new!(str)}
  rescue
    _ -> {:error, {:malformed_source_uri, str}}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp transient_db(ctx) do
    ctx |> Map.get(:transients, %{}) |> Map.get(:db)
  end

  defp positive_k(k, _ctx) when is_integer(k) and k > 0, do: k
  defp positive_k(_k, ctx), do: ctx[:read].(:default_k, 5)

  defp now, do: DateTime.utc_now()
end

defmodule Ezagent.Credential.GrantMint do
  @moduledoc """
  #201-cred (codex r2 HIGH-1/2/5) — the DEFERRED credential-grant mint.

  The grant is the security-critical durable state of the spawn path. It is
  therefore minted ONLY by the spawn attempt that proved it created the agent
  — after the immutable `:started ∧ created?` spawn receipt, immediately
  before credential materialization — never speculatively before the receipt.
  A losing (`:already_started`), adopting, rehydrating (`:started ∧
  ¬created?`), or exception-raising attempt never reaches this module, so no
  compensate-the-loser machinery exists to fail.

  The domain cascade (`Ezagent.Entity.Agent.TemplateSpawn.Cascade`) resolves
  the credential source and AUTHORIZES it (a read-only cap check) at
  resolution time, producing a plain-data **pending-grant descriptor**. The
  flavor plugin carries that descriptor into its created-winner arm and calls
  `mint/2` here right before it materializes.

  ## Pending-grant descriptor

    * `%{kind: :authorized, source: URI.t(), approved_by: URI.t(),
      holder_generation: pos_integer(), source_generation: pos_integer()}` —
      produced by `Ezagent.Credential.Resolver.authorize_grant/1`. The
      recorded authority generations are re-validated UNDER LOCK at insert
      time: if the authorizing holder or the source regenerated between
      authorization and the mint, the insert is rejected with
      `{:error, {:stale_authority_generation, uri}}` (codex r2 HIGH-5).
    * `%{kind: :workspace_shared, workspace_uri: URI.t(), flavor: String.t(),
      source: URI.t()}` — the no-cap workspace-shared fallback; the shared
      source registration is re-validated at mint time (no authority
      generations apply — there is no cap-borne holder).

  ## Confirmed compensation

  The only remaining cleanup is the created-winner's own post-mint failure
  (its spawn aborted after the mint). `compensate/3` deletes EXACTLY the
  minted incarnation — ABA-safe via `GrantRow.delete_incarnation/2` — and is
  CONFIRMED, never best-effort: it retries the delete and returns
  `{:error, :grant_compensation_failed}` when the row cannot be confirmed
  absent, so the failure propagates to the caller instead of silently
  leaving a durable grant (codex r2 HIGH-2).
  """

  require Logger

  alias Ezagent.Credential.{GrantRow, WorkspaceSharedSource}

  @typedoc "A plain-data authorization receipt produced at cascade-resolution time."
  @type pending :: %{
          required(:kind) => :authorized | :workspace_shared,
          optional(atom()) => term()
        }

  @compensate_attempts 3
  @compensate_backoff_ms 50

  @doc """
  Mint the durable grant for a resolved+authorized pending descriptor.

  `agent_uri` is the agent being created (the created-winner's own URI).
  Returns `{:ok, %GrantRow{}}` carrying the freshly minted
  `incarnation_id` (the caller's compensation receipt), or `{:error, reason}`
  (the caller MUST abort the spawn — nothing was written).

  #201-cred (codex r2 NEW-HIGH-3) — `witness` is the MANDATORY structural
  created-winner proof (`Ezagent.Kind.CreatedWitness`), minted by
  `Ezagent.Kind.spawn_receipt/3` and threaded from the plugin created-winner arm
  (directly for curl, via the cascade map for file flavors). A caller that did
  not just create `agent_uri` has no witness bound to it, so `mint/3`
  fail-closes with `{:error, :missing_created_winner_witness}` and writes
  NOTHING BEFORE evaluating the descriptor — grant-minting is structurally
  confined to the created-winner arm; no exported path (resolver, curl, a future
  plugin, a `curl`-driven RPC) can insert a durable grant without it.
  """
  @spec mint(URI.t(), pending(), Ezagent.Kind.CreatedWitness.t() | nil) ::
          {:ok, GrantRow.t()} | {:error, term()}
  def mint(%URI{} = agent_uri, pending, witness) do
    if Ezagent.Kind.CreatedWitness.authorizes?(witness, agent_uri) do
      do_mint(agent_uri, pending)
    else
      {:error, :missing_created_winner_witness}
    end
  end

  defp do_mint(%URI{} = agent_uri, %{kind: :authorized} = pending) do
    %{source: %URI{} = source, approved_by: %URI{} = approved_by} = pending

    if Ezagent.Capability.workspace_of(agent_uri) == Ezagent.Capability.workspace_of(source) do
      insert_guarded(agent_uri, source, approved_by, pending)
    else
      {:error, :agent_source_workspace_mismatch}
    end
  end

  defp do_mint(%URI{} = agent_uri, %{kind: :workspace_shared} = pending) do
    %{
      workspace_uri: %URI{} = workspace_uri,
      flavor: flavor,
      source: %URI{} = source
    } = pending

    # Re-validate the shared-source registration AT MINT TIME (the resolve-time
    # check may be stale by the time the created-winner mints).
    with true <-
           Ezagent.Capability.workspace_of(agent_uri) ==
             Ezagent.Capability.workspace_of(source),
         %WorkspaceSharedSource{} = row <-
           WorkspaceSharedSource.get(URI.to_string(workspace_uri), flavor),
         true <- row.source_uri == URI.to_string(source),
         set_by when is_binary(set_by) and set_by != "" <- row.set_by do
      GrantRow.insert(%{
        agent_uri: URI.to_string(agent_uri),
        credential_source_uri: URI.to_string(source),
        approved_by: set_by,
        approved_scope: URI.to_string(source),
        version: 1
      })
    else
      _ -> {:error, {:source_unauthorized, source}}
    end
  end

  defp do_mint(%URI{}, pending), do: {:error, {:invalid_pending_grant, pending}}

  @doc """
  `maybe_mint/3` is the materialization-boundary entry point: a cascade that
  carries no pending grant (no credential source resolved, or a rehydrated
  respawn cascade — a respawn NEVER mints) is a `{:ok, nil}` no-op, regardless
  of the witness. When a pending grant IS present, the durable mint requires the
  created-winner `witness` (#201-cred codex r2 NEW-HIGH-3) exactly as `mint/3`.
  """
  @spec maybe_mint(URI.t(), pending() | nil, Ezagent.Kind.CreatedWitness.t() | nil) ::
          {:ok, GrantRow.t() | nil} | {:error, term()}
  def maybe_mint(%URI{}, nil, _witness), do: {:ok, nil}

  def maybe_mint(%URI{} = agent_uri, %{} = pending, witness),
    do: mint(agent_uri, pending, witness)

  @doc """
  Confirmed, ABA-safe deletion of EXACTLY the incarnation `agent_uri_str`'s
  spawn attempt minted. Retries the delete (`:attempts`, default
  #{@compensate_attempts}) and only reports `:ok` when the row is confirmed
  absent (deleted, or already gone — a no-op when another path already
  removed it or replaced it with a NEWER incarnation, which this delete must
  NOT touch). A persistent failure returns
  `{:error, :grant_compensation_failed}` and logs `:critical` — the caller
  must surface it, never swallow it (codex r2 HIGH-2: best-effort
  rescue-to-`:ok` compensation silently leaked loser grants).

  `:delete_fun` is a test seam (defaults to
  `GrantRow.delete_incarnation/2`).
  """
  @spec compensate(String.t(), String.t(), keyword()) ::
          :ok | {:error, :grant_compensation_failed}
  def compensate(agent_uri_str, incarnation_id, opts \\ [])
      when is_binary(agent_uri_str) and is_binary(incarnation_id) do
    delete_fun = Keyword.get(opts, :delete_fun, &GrantRow.delete_incarnation/2)
    attempts = Keyword.get(opts, :attempts, @compensate_attempts)
    backoff = Keyword.get(opts, :backoff_ms, @compensate_backoff_ms)

    case do_compensate(agent_uri_str, incarnation_id, delete_fun, attempts, backoff) do
      :ok ->
        :ok

      :exhausted ->
        Logger.critical(
          "credential grant compensation EXHAUSTED retries: " <>
            "agent_uri=#{agent_uri_str} incarnation_id=#{incarnation_id} — " <>
            "the minted grant may remain durable; operator intervention required"
        )

        {:error, :grant_compensation_failed}
    end
  end

  defp do_compensate(_uri, _inc, _fun, attempts, _backoff) when attempts <= 0, do: :exhausted

  defp do_compensate(agent_uri_str, incarnation_id, delete_fun, attempts, backoff) do
    case delete_fun.(agent_uri_str, incarnation_id) do
      {:ok, _deleted_or_no_grant} ->
        :ok

      {:error, _reason} ->
        Process.sleep(backoff)
        do_compensate(agent_uri_str, incarnation_id, delete_fun, attempts - 1, backoff)
    end
  rescue
    _ ->
      Process.sleep(backoff)
      do_compensate(agent_uri_str, incarnation_id, delete_fun, attempts - 1, backoff)
  catch
    _, _ ->
      Process.sleep(backoff)
      do_compensate(agent_uri_str, incarnation_id, delete_fun, attempts - 1, backoff)
  end

  @doc "The compensation receipt of a minted grant row (or nil)."
  @spec grant_incarnation(GrantRow.t() | nil) :: String.t() | nil
  def grant_incarnation(nil), do: nil
  def grant_incarnation(%GrantRow{incarnation_id: inc}), do: inc

  # Generation-guarded insert (codex r2 HIGH-5): re-read the authorizing
  # holder's and the source's CURRENT active authority generations under a
  # row lock inside the insert transaction; a generation that moved since
  # authorization aborts the mint (`:stale_authority_generation`). A
  # concurrent regenesis serializes against the locked active row; the
  # materialize-time revalidation (`GrantRow.fetch_for_materialize/1`)
  # closes any residual window.
  defp insert_guarded(%URI{} = agent_uri, %URI{} = source, %URI{} = approved_by, pending) do
    EzagentCore.Repo.transaction(fn ->
      with :ok <-
             check_generation(approved_by, Map.get(pending, :holder_generation)),
           :ok <- check_generation(source, Map.get(pending, :source_generation)) do
        case GrantRow.insert(%{
               agent_uri: URI.to_string(agent_uri),
               credential_source_uri: URI.to_string(source),
               approved_by: URI.to_string(approved_by),
               approved_scope: URI.to_string(source),
               version: 1,
               holder_generation: Map.get(pending, :holder_generation),
               source_generation: Map.get(pending, :source_generation)
             }) do
          {:ok, row} -> row
          {:error, reason} -> EzagentCore.Repo.rollback(reason)
        end
      else
        {:error, reason} -> EzagentCore.Repo.rollback(reason)
      end
    end)
  end

  defp check_generation(_uri, nil), do: :ok

  defp check_generation(%URI{} = uri, expected) do
    case lock_current_generation(uri) do
      {:ok, ^expected} -> :ok
      _ -> {:error, {:stale_authority_generation, uri}}
    end
  end

  # SELECT ... FOR UPDATE on the CURRENT active authority row: a concurrent
  # regenesis (which retires that row in its own transaction) serializes
  # against this lock. No active row ⇒ the authority is gone ⇒ stale.
  defp lock_current_generation(%URI{} = uri) do
    import Ecto.Query

    key = uri |> Ezagent.URI.instance() |> Ezagent.URI.stable_key()

    from(row in Ezagent.Ecto.KindCapAuthority,
      where: row.uri == ^key and row.active == true,
      lock: "FOR UPDATE",
      select: row.generation
    )
    |> EzagentCore.Repo.one()
    |> case do
      generation when is_integer(generation) -> {:ok, generation}
      nil -> :error
    end
  rescue
    _ -> :error
  end
end

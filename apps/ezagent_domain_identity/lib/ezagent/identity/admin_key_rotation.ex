defmodule Ezagent.Identity.AdminKeyRotation do
  @moduledoc """
  Manual operator command to rotate the genesis admin's (authority root's)
  signing key (#1627 B1-hybrid, Allen's requirement).

  The admin is structurally UN-KILLABLE — every bare gen-bump path
  (`Cap.revoke_all_to/2`, `DeleteUser`, `Authority.regenesis/2`) rejects
  `admin_uri()`. Key rotation must nonetheless EXIST as an operator op. This is
  the ONLY sanctioned way to advance the root's generation: it rotates the
  authority AND re-mints the self-license UNDER THE NEW GENERATION in a single
  transaction under the authority-row lock, so a legitimate rotation NEVER leaves
  a stale-generation admin window.

  ## Invocation

      # dev/test:
      mix ezagent.identity.rotate_admin
      # release node (no Mix):
      bin/ezagent eval "EzagentCore.Release.rotate_admin()"

  ## Atomicity + liveness

  `rotate_mint_persist/1` is ONE `Repo.transaction` under the authority-row lock
  that `rotate_root_generation`s the root (the sole root-permitted bump), mints
  the self-license under the returned NEW authority (current by construction), AND
  writes it to the AUTHORITATIVE durable plane (the identity-caps `Store` — what a
  boot reads) — all commit together (codex r3 hardening 2). Folding the
  authoritative persist INTO the transaction closes the crash window the prior
  layout left open: rotate+mint committed, then a crash before a SEPARATE persist
  stranded the authority at gen N+1 with a durable gen-N license →
  `:holder_revoked` boot brick. A persist failure now `Repo.rollback`s the whole
  rotation (authority stays gen N, the old license stays valid). Only the
  authoritative write is in-transaction. The live
  admin Kind is then terminated so its next reference re-spawns on the new
  generation.
  """

  require Logger

  alias Ezagent.Cap.Authority
  alias Ezagent.Entity.User
  alias EzagentCore.Repo

  @doc """
  Rotate the genesis admin's authority + re-mint its self-license atomically.
  Returns `{:ok, new_generation}` or `{:error, reason}`. `opts[:io]` (default
  `IO.puts/1`) receives a human-readable success line.
  """
  @spec run(keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def run(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)
    admin = User.admin_uri()

    with {:ok, _licensed} <- rotate_mint_persist(admin),
         :ok <- refresh_live_admin(admin),
         {:ok, generation} <- Authority.current_generation(admin) do
      io.(
        "admin authority rotated to generation #{generation}; self-license " <>
          "re-minted under the new generation and persisted."
      )

      {:ok, generation}
    else
      :error ->
        {:error, :admin_generation_unreadable}

      {:error, reason} = error ->
        Logger.error("AdminKeyRotation: rotation failed: #{inspect(reason)}")
        error
    end
  end

  # ONE transaction under the authority-row lock (codex r3 hardening 2 —
  # atomicity): rotate the root authority (the sole root-permitted bump) + mint
  # the self-license under the returned NEW authority + write it to the
  # AUTHORITATIVE durable plane — all commit together. Folding the authoritative
  # persist INTO the transaction closes the crash window the prior layout left
  # open (rotate+mint committed, then a crash before a SEPARATE persist stranded
  # the authority at gen N+1 with a durable gen-N license → post-epoch
  # `:holder_revoked` boot brick). The minted license is current BY CONSTRUCTION
  # (signed under the just-rotated authority); `Store.persist`'s own
  # current-generation license check runs on THIS in-txn connection, so it SEES
  # the uncommitted new authority row (single primary Repo, no read replica) and
  # lands the store row `active`. A persist failure `Repo.rollback`s everything
  # (authority stays gen N, old license valid). Only the AUTHORITATIVE write is
  # folded in; the best-effort Kind snapshot projection stays OUTSIDE (F2).
  defp rotate_mint_persist(admin) do
    Repo.transaction(fn ->
      :ok = Authority.lock_current_generation(admin)

      with {:ok, new_authority} <- Authority.rotate_root_generation(admin, :user),
           {:ok, licensed} <-
             Authority.with_current(new_authority, fn ->
               Ezagent.ActionSet.Identity.mint_self_license(MapSet.new(), admin)
             end),
           :ok <- persist_authoritative(admin, MapSet.to_list(licensed)) do
        licensed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, licensed} -> {:ok, licensed}
      {:error, reason} -> {:error, reason}
    end
  end

  # TEST-ONLY forced-failure seam (same `Mix.env() == :test` precedent as the
  # Store's test-only fault-injection seams): compiled
  # IN only for `MIX_ENV=test`, so a dev/prod/release build is a direct
  # `Store.persist/2` call and the seam is provably unreachable. Consulted ONLY
  # when `:ezagent_domain_identity, :admin_rotation_forced_persist_error` is set
  # (never outside the one atomicity regression) — a pure no-op off that path. It
  # lets the regression fail the AUTHORITATIVE in-txn persist and prove the whole
  # rotation rolls back (authority still gen N, old license still valid).
  @persist_failure_seam Mix.env() == :test

  # The AUTHORITATIVE durable self-license write, run INSIDE `rotate_mint_persist`'s
  # transaction. The identity-caps Store is the sole boot authority and the
  # plane whose stale license `:holder_revoked`-bricks boot. `Store.persist`
  # is self-contained authoritative (its own nested savepoint, no
  # best-effort-outside step), so folding it in is F2-safe. `{:error, _}` makes the
  # caller `Repo.rollback` the whole rotation.
  if @persist_failure_seam do
    defp persist_authoritative(admin, caps_list) do
      case Application.get_env(:ezagent_domain_identity, :admin_rotation_forced_persist_error) do
        nil -> Ezagent.IdentityCaps.Store.persist(admin, caps_list)
        reason -> {:error, reason}
      end
    end
  else
    defp persist_authoritative(admin, caps_list) do
      Ezagent.IdentityCaps.Store.persist(admin, caps_list)
    end
  end

  # Refresh the live admin Kind (best-effort) so its next reference re-spawns on
  # the new generation + reloads the persisted current-generation license.
  defp refresh_live_admin(admin) do
    _ = Ezagent.Kind.terminate(admin)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end

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
  a stale-generation admin window (the pre-epoch auto-heal remains only for the
  reflow/restore case).

  ## Invocation

      # dev/test:
      mix ezagent.identity.rotate_admin
      # release node (no Mix):
      bin/ezagent eval "EzagentCore.Release.rotate_admin()"

  ## Atomicity + liveness

  `rotate_and_mint/1` is one `Repo.transaction` that `lock_current_generation`s
  the root's authority row, `rotate_root_generation`s it (the sole root-permitted
  bump), and mints the self-license under the returned NEW authority — current by
  construction. The license is then persisted durably (`UserStore.persist` —
  caps_json + the identity-caps store, epoch-aware), and the live admin Kind is
  terminated so its next reference re-spawns on the new generation. A failure
  after the atomic rotate+mint (persist / terminate) leaves the durable authority
  advanced with the fresh license already minted; re-running is safe (it rotates
  again) and the boot re-ensure + pre-epoch auto-heal cover any interrupted run.
  """

  require Logger

  alias Ezagent.Cap.Authority
  alias Ezagent.Entity.User
  alias Ezagent.EntityCaps.UserStore
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

    with {:ok, licensed} <- rotate_and_mint(admin),
         :ok <- persist(admin, licensed),
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

  # ONE transaction under the authority-row lock: rotate the root authority (the
  # sole root-permitted bump) + mint the self-license under the returned NEW
  # authority. The minted license is current BY CONSTRUCTION (signed under the
  # just-rotated authority), so no in-transaction re-verify is needed (and none is
  # possible before commit — the `AuthorityCache` read-through cannot see the
  # uncommitted new authority row). No stale-gen window: authority rows +
  # freshly-signed license commit together.
  defp rotate_and_mint(admin) do
    Repo.transaction(fn ->
      :ok = Authority.lock_current_generation(admin)

      with {:ok, new_authority} <- Authority.rotate_root_generation(admin, :user),
           {:ok, licensed} <-
             Authority.with_current(new_authority, fn ->
               Ezagent.ActionSet.Identity.mint_self_license(MapSet.new(), admin)
             end) do
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

  # Persist the re-minted self-license durably (caps_json + the identity-caps
  # store, epoch-aware via `UserStore.update`), so cold reads / the next boot see
  # the current-generation license (required for POST-epoch nodes, where nothing
  # re-mints on `:existed`).
  defp persist(admin, licensed) do
    UserStore.persist(admin, MapSet.to_list(licensed))
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

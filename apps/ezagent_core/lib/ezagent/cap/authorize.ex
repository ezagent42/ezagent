defmodule Ezagent.Cap.Authorize do
  @moduledoc """
  The single authorization chokepoint facade (unified-revocation Phase F-1).

  `Ezagent.Cap.authorize/3` takes an EXPLICIT authenticated holder, the
  candidate caps presented, and the needed cap shape, and returns the
  authorizing cap or a denial — never a bare `Capability.matches?/2` match:

  1. **Principal gate (MF2), resolved independently.** The holder's caps are
     loaded from the dependency-inverted holder-cap source (the configured
     `Ezagent.Cap.AuthorityLoader`, today `Ezagent.Identity.read_held_caps/1`)
     — NEVER from the `candidate_caps` argument, so presented inline caps can
     never satisfy the principal gate. An empty independent load is
     fail-closed (`{:error, :holder_revoked}`). G-3 lands the self-license
     precondition inside that load source (a gen-bumped principal's load
     yields `[]`), which is what gives this gate its teeth; F-1 wires the
     seam.
  2. **Target gate.** Each candidate is verified against its target's
     CURRENT active authority row via
     `Ezagent.Cap.Authority.verify_against_current/3` — the fresh-read
     revocation basis (signature + generation, never the cached process
     authority). Unsigned, tampered, retargeted, scope-tuple, or old-gen
     candidates are dropped.
  3. **Shape match.** The first verified candidate matching the `needed`
     shape authorizes.

  Later phases extend THIS one function: F-2 routes the bare-matches bypass
  engines through it, F-6 threads the authenticated holder into every caller,
  M-1 adds the membership predicate.
  """

  alias Ezagent.Cap.{Authority, RevocationLedger}
  alias Ezagent.Capability

  @type denial :: {:error, :holder_revoked | :no_matching_cap}

  @doc """
  Authorize `holder` for `needed` given the presented `candidate_caps`.

  Returns `{:ok, cap}` with the authorizing cap, `{:error, :holder_revoked}`
  when the holder's independently-loaded cap set is empty, or
  `{:error, :no_matching_cap}` when no verified candidate matches.
  """
  @spec authorize(URI.t(), Enumerable.t(), map()) :: {:ok, Capability.t()} | denial()
  def authorize(%URI{} = holder, candidate_caps, needed) when is_map(needed) do
    case {principal_fenced?(holder), principal_current?(holder)} do
      {true, _current?} ->
        {:error, :holder_revoked}

      {false, false} ->
        {:error, :holder_revoked}

      {false, true} ->
        verified = Enum.filter(candidate_caps, &verified_candidate?(&1, holder))

        case RevocationLedger.filter_unrevoked(Ezagent.URI.workspace_of(holder), verified) do
          {:ok, unrevoked} ->
            case Enum.find(unrevoked, &Capability.matches?(&1, needed)) do
              %Capability{} = cap -> {:ok, cap}
              nil -> {:error, :no_matching_cap}
            end

          {:error, _reason} ->
            {:error, :no_matching_cap}
        end
    end
  end

  defp verified_candidate?(%Capability{} = cap, holder) do
    case Authority.target_uri(cap) do
      {:ok, target} -> Authority.verify_against_current(cap, holder, target)
      {:error, :concrete_target_required} -> false
    end
  rescue
    _ -> false
  end

  defp verified_candidate?(_candidate, _holder), do: false

  # A principal is current iff its independently-loaded holder store (the
  # dependency-inverted `read_held_caps/1` loader) yields a non-empty verified
  # cap set. The G-3 self-license gate INSIDE that loader makes a gen-bumped
  # principal load EMPTY, so a standalone generation bump immediately makes the
  # principal inert.
  #
  # The former `autonomous_current?/1` process-generation branch (spec §5 C4)
  # is removed: it read AMBIENT actor-process state (`current_process_generation`
  # via `Process.get`), coupling the authz plane to the actor runtime. Every
  # principal that could pass ONLY via that branch already holds a DURABLE
  # current-generation self-license before `ReadyGate` reports ready — the
  # creation-time mint (`create_freshness: :created`) is persisted fail-closed
  # on the pre-ready boot path (snapshot-backed via the initial-snapshot commit;
  # user-backed via `activate/2`'s marker-gated projection persist), so the
  # branch is dead code (proven empty by the §5-C4 precondition-1 enumerator).
  defp principal_current?(holder) do
    holder_caps(holder) != []
  end

  # The holder-cap source is fail-closed: an unloaded/unreadable holder is a
  # revoked holder, never a default-allow.
  defp holder_caps(holder) do
    holder |> loader().read_held_caps() |> Enum.to_list()
  rescue
    _ -> []
  end

  # The domain-backed fence read is fail-closed. Only an explicit `false`
  # admits the holder; a missing callback, exception, or malformed return is a
  # deny so configuration drift cannot silently disable an offboarding fence.
  defp principal_fenced?(holder) do
    loader().principal_fenced?(holder) != false
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  defp loader do
    :ezagent_core
    |> Application.fetch_env!(Ezagent.Cap)
    |> Keyword.fetch!(:authority_loader)
  end
end

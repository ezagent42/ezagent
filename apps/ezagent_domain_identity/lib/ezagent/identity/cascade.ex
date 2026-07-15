defmodule Ezagent.Identity.Cascade do
  @moduledoc """
  Cascade-notification resolver + content-free notify (membership-cap unification
  Phase B, spec §10 / K3-K5).

  ## `managers_of/1` — the bounded reverse-authority scan (B.2, K4/K5)

  Given a changed entity `X`, resolve the **User** URIs holding one-level
  manage/owner authority over `X`, bounded to `X`'s workspace:

    1. `ws = workspace_of(X)` — O(1) from the URI.
    2. candidates = `Ezagent.Users.list_in_workspace(ws)` (bounded per-workspace;
       Users ONLY — agents can't be notified yet, spec §11/S2).
    3. per candidate, read **LIVE** caps via `Ezagent.EntityCaps.load/1`
       (K5 — NOT `users.caps_json`), apply `Capability.granted_by_entity?/1` (K4 —
       so a stale/system-granted cap does not over-match), then match a
       `Manage`-over-`X` cap OR a workspace-admin cap via `Ezagent.Identity.Authority`.
    4. dedupe.

  **Skip-self (deadlock + semantics):** the changed entity `X` is excluded from
  the candidate scan. The cascade runs as a post-commit dispatch INSIDE `X`'s own
  `Kind.Server` (B.3); `EntityCaps.load(X)` would be a `GenServer.call` to that
  same process — a self-slice deadlock (the `runtime.ex:393-407` hazard A2's
  `MemberReceive` also dodges). Semantically we notify `X`'s *managers*, never
  `X` itself, so the skip is correct regardless.

  This is the same reverse-authority machinery Part A's cold reconcile uses, but
  deliberately distinct from delivery's "members of S" (served hot from the
  projection cache): "managers of X" is the cold, bounded per-cap-change scan.
  Do not blur the two queries.

  ## `notify_managers/2` — content-free advisory notify (B.3, spec §10 payload)

  See `notify_managers/2`.
  """

  require Logger

  alias Ezagent.Capability
  alias Ezagent.Identity.Authority

  @doc """
  Resolve the User URIs with one-level manage/owner authority over `x`, bounded
  to `x`'s workspace. See the moduledoc for the algorithm + skip-self rationale.
  """
  @spec managers_of(URI.t()) :: [URI.t()]
  def managers_of(%URI{} = x) do
    ws = Capability.workspace_of(x)
    x_str = URI.to_string(x)

    ws
    |> Ezagent.Users.list_in_workspace()
    |> Stream.map(& &1.uri)
    |> Stream.reject(&(URI.to_string(&1) == x_str))
    |> Stream.filter(&manages_via_live_caps?(&1, x, ws))
    |> Enum.uniq_by(&URI.to_string/1)
  end

  def managers_of(_), do: []

  @doc """
  Notify the managers/owners of `x` of an allowlisted slice-change — the
  **content-free**, advisory cascade delivery (B.3, spec §10 payload).

  The notification body carries ONLY `{uri, slice_key, cursor, event_at}` — NO
  cap values, NO caller, NO member list (the same security-minimal discipline as
  the `slice_changed` envelope's HIGH-1 leak fix). An authorized recipient
  re-fetches detail via a cap-gated read.

  **Users-only sink (spec §11/S2):** `Ezagent.Notifications.notify/2` raises for a
  non-User recipient. `managers_of/1` already returns Users only, but every send
  is wrapped best-effort (rescue + catch) so a raise/failure on one recipient is
  logged and non-fatal — the cascade is off the mutating dispatch's critical path
  and MUST NOT crash it.

  Returns `:ok` always.
  """
  @spec notify_managers(URI.t() | String.t(), map()) :: :ok
  def notify_managers(x, args) when is_map(args) do
    with {:ok, %URI{} = x_uri} <- coerce_uri(x) do
      body = %{
        uri: URI.to_string(x_uri),
        slice_key: Map.get(args, :slice_key),
        cursor: Map.get(args, :cursor),
        event_at: Map.get(args, :event_at)
      }

      x_uri
      |> managers_of()
      |> Enum.each(fn %URI{} = user -> notify_one(user, body) end)
    end

    :ok
  end

  def notify_managers(_x, _args), do: :ok

  defp notify_one(%URI{} = user, body) do
    Ezagent.Notifications.notify(user, %{
      type: :entity_slice_changed,
      source: __MODULE__,
      body: body
    })
  rescue
    error ->
      Logger.warning(
        "Ezagent.Identity.Cascade: notify failed for #{URI.to_string(user)} " <>
          "(non-fatal, advisory): #{inspect(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Ezagent.Identity.Cascade: notify threw for #{URI.to_string(user)} " <>
          "(non-fatal, advisory): #{inspect({kind, reason})}"
      )

      :ok
  end

  defp coerce_uri(%URI{} = uri), do: {:ok, uri}

  defp coerce_uri(str) when is_binary(str) do
    {:ok, Ezagent.URI.new!(str)}
  rescue
    _ -> :error
  end

  defp coerce_uri(_), do: :error

  # Read the candidate's LIVE identity caps (K5), provenance-filter (K4), then
  # match a Manage-over-X cap OR a workspace-admin cap (the extracted B.1
  # predicates). NOTE the provenance filter lives HERE (the caller), not inside
  # the shared predicates — `Authority.manages?/2`'s admin branch must still
  # recognize the system-granted genesis wildcard.
  defp manages_via_live_caps?(%URI{} = candidate, %URI{} = x, %URI{} = ws) do
    caps =
      candidate
      |> Ezagent.EntityCaps.load()
      |> Enum.filter(&Capability.granted_by_entity?/1)

    Authority.holds_manage_over_target?(caps, x) or Authority.workspace_admin?(caps, ws)
  end
end

defmodule Ezagent.Socialware.ShareClaim do
  @moduledoc """
  Per-claimer record for URI-share (A1, Feishu model) — "this entity accepted the
  share link for this target".

  This is the OTHER half of the Feishu two-layer split from `ShareSetting`:

    * `ShareSetting` (per-target) = the owner's live sharing TOGGLE + what a link
      grants.
    * `ShareClaim` (per target × grantee) = who has clicked/accepted the link.

  Access is **re-derived live**, not minted: a claimer has access to `target`
  iff `ShareSetting.active(target)` is still enabled AND a `ShareClaim` row for
  `(target, grantee)` exists. So the owner turning the setting off cuts every
  claimer off instantly (codex Fix 1 — access-time recheck), exactly like Feishu
  "anyone with the link can view" — clicking the link does not make you a durable
  collaborator, it just records the claim; the live toggle governs access. The
  claim record is NEVER itself a capability — the live gate at the domain read
  chokepoint (`SessionReads.authorize_external_read` / `WorkspaceReads`) AND-s it
  with `ShareSetting.active/1`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias EzagentCore.Repo

  @primary_key false
  schema "socialware_share_claims" do
    field(:target_uri, :string, primary_key: true)
    field(:grantee_uri, :string, primary_key: true)
    field(:workspace_uri, :string)
    field(:claimed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Record that `grantee` accepted the share link for `target`. Idempotent
  (one row per target × grantee). The caller (`Share.claim/2`) has already
  verified the link and that sharing is currently enabled — this only durably
  notes the acceptance so the live access gate can find it later.
  """
  @spec record(URI.t(), URI.t()) :: {:ok, t()} | {:error, term()}
  def record(%URI{} = target, %URI{} = grantee) do
    now = DateTime.utc_now()

    %__MODULE__{}
    |> cast(
      %{
        target_uri: uri_string(target),
        grantee_uri: uri_string(grantee),
        workspace_uri: uri_string(Ezagent.Capability.workspace_of(target)),
        claimed_at: now
      },
      [:target_uri, :grantee_uri, :workspace_uri, :claimed_at]
    )
    |> validate_required([:target_uri, :grantee_uri, :workspace_uri])
    |> Repo.insert(
      on_conflict: {:replace, [:claimed_at, :updated_at]},
      conflict_target: [:target_uri, :grantee_uri]
    )
  end

  @doc "True iff `grantee` has an accepted claim on `target`."
  @spec claimed?(URI.t(), URI.t()) :: boolean()
  def claimed?(%URI{} = target, %URI{} = grantee) do
    not is_nil(
      Repo.get_by(__MODULE__, target_uri: uri_string(target), grantee_uri: uri_string(grantee))
    )
  end

  @doc """
  Drop `grantee`'s claim on `target` (e.g. an explicit un-share of one person).
  No-op if there is none. Turning the whole `ShareSetting` off does not need this
  — the live gate already denies once the setting is disabled; this is for
  removing a single claimer while sharing stays on.
  """
  @spec drop(URI.t(), URI.t()) :: :ok
  def drop(%URI{} = target, %URI{} = grantee) do
    case Repo.get_by(__MODULE__,
           target_uri: uri_string(target),
           grantee_uri: uri_string(grantee)
         ) do
      nil -> :ok
      %__MODULE__{} = row -> Repo.delete!(row) && :ok
    end
  end

  defp uri_string(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()
end

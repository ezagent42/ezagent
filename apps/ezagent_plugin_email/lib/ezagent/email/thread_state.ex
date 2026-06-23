defmodule Ezagent.Email.ThreadState do
  @moduledoc """
  Durable RFC 5322 threading state for the email ExternalMirror Binding
  (#88 PR-1 / SPEC §4.3 / HIGH 5).

  Pure data module — `Ezagent.Email.Binding.publish/2` is the only writer.
  Keyed by `binding_row_id` (the
  `Ezagent.ExternalMirror.BindingRow.row_id/3` value); one thread per
  binding. The Binding computes that id from the SERVER-STAMPED
  `msg.session_uri` (never caller opts) so it always matches the parent
  `external_mirror_bindings` row (the FK parent — `ON DELETE CASCADE`
  clears this on unbind, so rebind starts a fresh thread; see the
  migration moduledoc).

  Fields:
  - `root_message_id` — the FIRST outbound `Message-ID` (the thread root).
  - `last_message_id` — the most recent outbound `Message-ID` (the next
    `In-Reply-To` target).
  - `references_chain` — the full space-joined `References` header value,
    growing on every outbound send (RFC 5322 — full chain, not root+last).
  - `workspace_uri` — per-tenant scoping (invariant #14), derived from the
    session by the Binding.
  """

  use Ecto.Schema

  alias EzagentCore.Repo

  @primary_key {:binding_row_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "email_thread_state" do
    field(:root_message_id, :string)
    field(:last_message_id, :string)
    field(:references_chain, :string)
    field(:workspace_uri, :string)

    timestamps()
  end

  @type t :: %__MODULE__{
          binding_row_id: String.t(),
          root_message_id: String.t() | nil,
          last_message_id: String.t() | nil,
          references_chain: String.t() | nil,
          workspace_uri: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Load the durable thread state for `binding_row_id`, or `nil` when no
  outbound mail has been sent on this binding yet (first send mints it).
  """
  @spec load(String.t()) :: t() | nil
  def load(binding_row_id) when is_binary(binding_row_id) do
    Repo.get(__MODULE__, binding_row_id)
  end

  @doc """
  Upsert the thread state. Called by the Binding AFTER a successful send,
  inside the same logical step. `attrs` must carry `:root_message_id`,
  `:last_message_id`, `:references_chain`, `:workspace_uri`.

  On conflict (the row exists) the mutable threading fields are replaced;
  `binding_row_id` (PK) is the conflict target. `workspace_uri` is NOT
  replaced on conflict — it is structural and immutable for the lifetime
  of a binding row.
  """
  @spec upsert(String.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(binding_row_id, attrs) when is_binary(binding_row_id) and is_map(attrs) do
    params = Map.put(attrs, :binding_row_id, binding_row_id)

    %__MODULE__{}
    |> Ecto.Changeset.cast(params, [
      :binding_row_id,
      :root_message_id,
      :last_message_id,
      :references_chain,
      :workspace_uri
    ])
    |> Ecto.Changeset.validate_required([:binding_row_id, :workspace_uri])
    |> Repo.insert(
      on_conflict:
        {:replace, [:root_message_id, :last_message_id, :references_chain, :updated_at]},
      conflict_target: :binding_row_id
    )
  end
end

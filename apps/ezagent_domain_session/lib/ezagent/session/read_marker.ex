defmodule Ezagent.Session.ReadMarker do
  @moduledoc """
  Per-`(session, user, source)` read marker — "what's the latest
  message this user has SEEN via this source?".

  ## Sources

  - `:delivered` — transport (Feishu HTTP POST / LV WS) successfully
    sent the message envelope. LOW confidence: doesn't mean the human
    saw it.
  - `:displayed` — UI rendered the message in viewport. MEDIUM
    confidence: human's screen showed it, but they might not have
    looked.
  - `:read` — recipient explicitly confirmed (e.g. Feishu's
    `message_read` SDK event). HIGH confidence: human definitely saw.

  Consumers (LV unread badge, chat stream ✓✓ render) pick the
  highest-confidence source available for the user-session pair.

  See SPEC `docs/superpowers/specs/2026-05-23-read-receipts.md`.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias EzagentCore.Repo

  @type source :: :delivered | :displayed | :read
  @valid_sources [:delivered, :displayed, :read]
  @valid_source_strings ~w(delivered displayed read)

  # Confidence ranking — higher = more authoritative.
  @confidence %{
    "read" => 3,
    "displayed" => 2,
    "delivered" => 1
  }

  schema "read_markers" do
    field(:workspace_uri, :string)
    field(:session_uri, :string)
    field(:user_uri, :string)
    field(:source, :string)
    field(:last_read_message_uri, :string)
    field(:observed_at, :utc_datetime_usec)

    timestamps()
  end

  # ----- Write side ----------------------------------------------------------

  @doc """
  Record that `user_uri` has seen up to `message_uri` in `session_uri`
  via `source`. Upsert keyed on (workspace, session, user, source);
  bumps `last_read_message_uri` if `message_uri` is later than the
  current marker (compared by `messages.inserted_at`).

  Idempotent on repeat with same `(uri, message, source)` (no-op).
  Out-of-order events (older message than current marker) are ignored
  with `{:ok, :already_ahead}` — NOT an error.

  Broadcasts `{:read_marker_updated, session_uri, user_uri, %{source,
  last_read_message_uri, observed_at}}` on the session events topic
  on successful update.
  """
  @spec mark(URI.t() | String.t(), URI.t() | String.t(), URI.t() | String.t(), source()) ::
          {:ok, :updated | :already_ahead} | {:error, term()}
  def mark(session_uri, user_uri, message_uri, source) when source in @valid_sources do
    session_str = to_str(session_uri)
    user_str = to_str(user_uri)
    msg_str = to_str(message_uri)
    src_str = Atom.to_string(source)

    case derive_workspace(session_uri) do
      {:ok, ws_uri} ->
        do_mark(ws_uri, session_str, user_str, msg_str, src_str)

      :error ->
        {:error, {:invalid_session_uri, session_str}}
    end
  end

  def mark(_, _, _, source), do: {:error, {:invalid_source, source}}

  defp do_mark(ws_uri, session_str, user_str, msg_str, src_str) do
    now = DateTime.utc_now()

    existing = get_marker(session_str, user_str, src_str)

    cond do
      is_nil(existing) ->
        insert_marker(ws_uri, session_str, user_str, src_str, msg_str, now)

      msg_str == existing.last_read_message_uri ->
        {:ok, :already_ahead}

      message_newer?(msg_str, existing.last_read_message_uri) ->
        update_marker(existing, msg_str, now)

      true ->
        {:ok, :already_ahead}
    end
  end

  defp insert_marker(ws_uri, session_str, user_str, src_str, msg_str, now) do
    changeset =
      changeset_for_insert(%{
        workspace_uri: ws_uri,
        session_uri: session_str,
        user_uri: user_str,
        source: src_str,
        last_read_message_uri: msg_str,
        observed_at: now
      })

    case Repo.insert(changeset) do
      {:ok, _row} ->
        broadcast(session_str, user_str, src_str, msg_str, now)
        {:ok, :updated}

      {:error, _} = err ->
        err
    end
  end

  defp update_marker(existing, msg_str, now) do
    cs =
      existing
      |> change(%{last_read_message_uri: msg_str, observed_at: now})

    case Repo.update(cs) do
      {:ok, _row} ->
        broadcast(existing.session_uri, existing.user_uri, existing.source, msg_str, now)
        {:ok, :updated}

      {:error, _} = err ->
        err
    end
  end

  defp changeset_for_insert(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :workspace_uri,
      :session_uri,
      :user_uri,
      :source,
      :last_read_message_uri,
      :observed_at
    ])
    |> validate_required([
      :workspace_uri,
      :session_uri,
      :user_uri,
      :source,
      :last_read_message_uri,
      :observed_at
    ])
    |> validate_inclusion(:source, @valid_source_strings)
    |> unique_constraint([:workspace_uri, :session_uri, :user_uri, :source],
      name: :read_markers_unique
    )
  end

  # ----- Read side -----------------------------------------------------------

  @doc """
  Unread message count for `(session, user)`. Uses the highest-confidence
  source available; falls back to "everything is unread" if no marker
  exists.
  """
  @spec unread_count(URI.t() | String.t(), URI.t() | String.t()) :: non_neg_integer()
  def unread_count(session_uri, user_uri) do
    session_str = to_str(session_uri)
    user_str = to_str(user_uri)

    markers = list_markers(session_str, user_str)

    case best_marker(markers) do
      nil ->
        # No marker — everything in this session is unread.
        count_messages_in_session(session_str)

      marker ->
        count_messages_after(session_str, marker.last_read_message_uri)
    end
  end

  @doc """
  Last_read_message_uri for `(session, user, source)`, or nil if no
  marker exists for that source.
  """
  @spec last_read(URI.t() | String.t(), URI.t() | String.t(), source()) :: String.t() | nil
  def last_read(session_uri, user_uri, source) when source in @valid_sources do
    session_str = to_str(session_uri)
    user_str = to_str(user_uri)
    src_str = Atom.to_string(source)

    case get_marker(session_str, user_str, src_str) do
      nil -> nil
      marker -> marker.last_read_message_uri
    end
  end

  @doc """
  All markers for `(session, user)` keyed by source atom — for LV
  chat stream to render per-message ✓ / ✓✓ / ✓✓✓ markers.
  """
  @spec list_for(URI.t() | String.t(), URI.t() | String.t()) :: %{
          source() => %{
            last_read_message_uri: String.t(),
            observed_at: DateTime.t()
          }
        }
  def list_for(session_uri, user_uri) do
    session_str = to_str(session_uri)
    user_str = to_str(user_uri)

    session_str
    |> list_markers(user_str)
    |> Enum.into(%{}, fn m ->
      {String.to_existing_atom(m.source),
       %{
         last_read_message_uri: m.last_read_message_uri,
         observed_at: m.observed_at
       }}
    end)
  end

  @doc """
  Move all read markers in `session_uri` from `from_uri` to `to_uri`.

  Collision-safe: if `to_uri` already has a marker for the same source, keep
  the more advanced marker and delete the `from_uri` row. Re-running the same
  repoint after a crash is a no-op.
  """
  @spec repoint(URI.t() | String.t(), URI.t() | String.t(), URI.t() | String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def repoint(session_uri, from_uri, to_uri) do
    session_str = to_str(session_uri)
    from_str = to_str(from_uri)
    to_str = to_str(to_uri)

    Repo.transaction(fn ->
      session_str
      |> list_markers(from_str)
      |> Enum.reduce(0, fn marker, moved ->
        repoint_marker(marker, session_str, to_str)
        moved + 1
      end)
    end)
  end

  # ----- Private -------------------------------------------------------------

  defp repoint_marker(marker, session_str, to_str) do
    case get_marker(session_str, to_str, marker.source) do
      nil ->
        marker
        |> change(%{user_uri: to_str})
        |> Repo.update!()

      target ->
        if message_newer?(marker.last_read_message_uri, target.last_read_message_uri) do
          target
          |> change(%{
            last_read_message_uri: marker.last_read_message_uri,
            observed_at: marker.observed_at
          })
          |> Repo.update!()
        end

        Repo.delete!(marker)
    end
  end

  defp get_marker(session_str, user_str, src_str) do
    Repo.one(
      from(m in __MODULE__,
        where:
          m.session_uri == ^session_str and
            m.user_uri == ^user_str and
            m.source == ^src_str
      )
    )
  end

  defp list_markers(session_str, user_str) do
    Repo.all(
      from(m in __MODULE__,
        where: m.session_uri == ^session_str and m.user_uri == ^user_str
      )
    )
  end

  defp best_marker(markers) do
    Enum.max_by(markers, fn m -> Map.get(@confidence, m.source, 0) end, fn -> nil end)
  end

  # Two messages compared by their `inserted_at` from the messages
  # table — the canonical ordering. Returns true if `new_uri` is
  # strictly later than `existing_uri`.
  defp message_newer?(new_uri, existing_uri) do
    case lookup_inserted_at_pair(new_uri, existing_uri) do
      {%DateTime{} = new_at, %DateTime{} = existing_at} ->
        DateTime.compare(new_at, existing_at) == :gt

      _ ->
        # If we can't compare (one missing), treat new as NOT newer
        # — conservative: false-negative means we'll keep the older
        # marker; better than promoting a stale marker.
        false
    end
  end

  defp lookup_inserted_at_pair(new_uri, existing_uri) do
    rows =
      Repo.all(
        from(msg in Ezagent.Message,
          where: msg.id in ^[new_uri, existing_uri],
          select: {msg.id, msg.inserted_at}
        )
      )

    by_uri = Enum.into(rows, %{})

    {Map.get(by_uri, new_uri), Map.get(by_uri, existing_uri)}
  end

  defp count_messages_in_session(session_str) do
    # Message session-scoping (2026-06-21): count `messages` directly by
    # `session_uri` (the `message_routings` join table was removed).
    Repo.one(
      from(m in Ezagent.Message,
        where: m.session_uri == ^session_str,
        select: count(m.id)
      )
    ) || 0
  end

  defp count_messages_after(session_str, after_message_uri) do
    case Repo.one(
           from(msg in Ezagent.Message,
             where: msg.id == ^after_message_uri,
             select: msg.inserted_at
           )
         ) do
      nil ->
        # Marker refers to a message that doesn't exist locally
        # (cross-node, replication gap). Conservatively report full
        # session count.
        count_messages_in_session(session_str)

      %DateTime{} = after_at ->
        Repo.one(
          from(m in Ezagent.Message,
            where: m.session_uri == ^session_str and m.inserted_at > ^after_at,
            select: count(m.id)
          )
        ) || 0
    end
  end

  # ----- PubSub --------------------------------------------------------------

  defp broadcast(session_str, user_str, src_str, msg_str, observed_at) do
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      Ezagent.ActionSet.Session.session_events_topic(session_str),
      {:read_marker_updated, Ezagent.URI.new!(session_str), Ezagent.URI.new!(user_str),
       %{
         source: String.to_existing_atom(src_str),
         last_read_message_uri: msg_str,
         observed_at: observed_at
       }}
    )
  end

  # ----- Workspace derivation ------------------------------------------------

  defp derive_workspace(uri) do
    parsed = if is_binary(uri), do: Ezagent.URI.new!(uri), else: uri

    try do
      {:ok, URI.to_string(Ezagent.Capability.workspace_of(parsed))}
    rescue
      _ -> :error
    end
  end

  defp to_str(%URI{} = uri), do: URI.to_string(uri)
  defp to_str(s) when is_binary(s), do: s
end

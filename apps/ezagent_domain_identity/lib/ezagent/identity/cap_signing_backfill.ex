defmodule Ezagent.Identity.CapSigningBackfill do
  @moduledoc """
  Read-only Phase-4 capability-signing backfill planner.

  This is deliberately a dry-run-only mechanism. Durable caps identify a
  holder and identity tuple, but never supply a replacement artifact. A
  proposed replacement is derived exclusively from a matching `cap_granted`
  EventLog payload and is immediately re-authorized through `Ezagent.Cap.issue/3`.
  The result is classified for an operator; it is never persisted by this
  module.
  """

  alias Ezagent.{Cap, Capability, EventLog, Users}
  alias Ezagent.Ecto.KindSnapshot

  @required_cap_fields ~w(kind behavior action instance workspace_uri granted_by granted_at)
  @optional_cap_fields ~w(signature key_id grantee_uri)
  @cap_fields @required_cap_fields ++ @optional_cap_fields

  @type home :: :users | :snapshot
  @type candidate :: %{
          required(:home) => home(),
          required(:holder) => URI.t(),
          required(:cap) => Capability.t()
        }

  @type report_entry :: %{
          required(:holder) => URI.t(),
          required(:identity_key) => tuple(),
          required(:status) => :would_sign | :quarantined | :skipped,
          optional(:reason) => term(),
          optional(:event_id) => term()
        }

  @type report :: %{
          scanned: non_neg_integer(),
          would_sign: non_neg_integer(),
          quarantined: non_neg_integer(),
          skipped: non_neg_integer(),
          entries: [report_entry()]
        }

  @doc """
  Read both durable homes and classify every candidate without mutating either.

  Test callers can provide only read/issue dependencies via `:candidates`,
  `:event_streamer`, and `:issue`. There is intentionally no write callback or
  apply mode in this API.
  """
  @spec dry_run(keyword()) :: {:ok, report()}
  def dry_run(opts \\ []) when is_list(opts) do
    candidates = Keyword.get_lazy(opts, :candidates, &durable_candidates/0)
    event_streamer = Keyword.get(opts, :event_streamer, &EventLog.stream_by_aggregate/1)
    issue = Keyword.get(opts, :issue, &Cap.issue/3)

    entries =
      candidates
      |> deduplicate()
      |> Enum.map(&classify(&1, event_streamer, issue))

    {:ok, report(entries)}
  end

  defp durable_candidates do
    user_candidates() ++ snapshot_candidates()
  end

  defp user_candidates do
    Users.list_all()
    |> Enum.flat_map(fn %{uri: holder, caps: caps} ->
      candidates_from_caps(:users, holder, caps)
    end)
  end

  defp snapshot_candidates do
    KindSnapshot.list_all()
    |> Enum.flat_map(&candidates_from_snapshot/1)
  end

  defp candidates_from_snapshot(%KindSnapshot{uri: uri} = snapshot) do
    with {:ok, holder} <- parse_uri(uri),
         {:ok, state} <- KindSnapshot.decode_state(snapshot) do
      candidates_from_caps(:snapshot, holder, identity_caps(state))
    else
      _ -> []
    end
  end

  defp candidates_from_caps(home, %URI{} = holder, caps)
       when is_list(caps) or is_struct(caps, MapSet) do
    Enum.flat_map(caps, fn
      %Capability{} = cap -> [%{home: home, holder: holder, cap: cap}]
      _ -> []
    end)
  end

  defp candidates_from_caps(_home, _holder, _caps), do: []

  defp identity_caps(%{identity: %{state: %{caps: caps}}}), do: cap_list(caps)
  defp identity_caps(%{identity: %{caps: caps}}), do: cap_list(caps)
  defp identity_caps(_state), do: []

  defp cap_list(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp cap_list(caps) when is_list(caps), do: caps
  defp cap_list(_caps), do: []

  defp deduplicate(candidates) do
    Enum.uniq_by(candidates, fn %{holder: holder, cap: cap} ->
      {
        Ezagent.URI.stable_key(holder),
        Capability.identity_key(cap),
        source_key(cap)
      }
    end)
  end

  # A users-row and a snapshot can carry the same logical capability, but a
  # different issuer/timestamp means they claim different EventLog sources.
  # Keep those sources distinct: the lifecycle replay will quarantine stale
  # ones instead of letting an identity-only dedupe select one arbitrarily.
  defp source_key(%Capability{granted_by: %URI{} = issuer, granted_at: %DateTime{} = granted_at}) do
    {Ezagent.URI.stable_key(issuer), DateTime.to_iso8601(granted_at)}
  end

  defp source_key(%Capability{granted_by: granted_by, granted_at: granted_at}),
    do: {inspect(granted_by), inspect(granted_at)}

  defp classify(%{holder: holder, cap: cap}, _event_streamer, _issue)
       when cap.granted_by == :plugin_declared do
    entry(holder, cap, :skipped, reason: :sentinel)
  end

  defp classify(%{holder: holder, cap: cap}, _event_streamer, _issue)
       when not is_struct(cap.granted_by, URI) or cap.granted_by.scheme != "entity" do
    entry(holder, cap, :skipped, reason: :non_authorizer)
  end

  defp classify(
         %{
           holder: holder,
           cap: %{signature: signature, key_id: key_id, grantee_uri: %URI{}} = cap
         },
         _event_streamer,
         _issue
       )
       when is_binary(signature) and is_binary(key_id) do
    entry(holder, cap, :skipped, reason: :already_signed)
  end

  defp classify(
         %{holder: holder, cap: %{signature: nil, key_id: nil, grantee_uri: nil} = cap},
         event_streamer,
         issue
       ) do
    case authoritative_event(event_streamer.(holder), holder, cap) do
      {:ok, %{event_id: event_id, issuer: issuer, proposal: proposal}} ->
        case issue.({:held_by, issuer}, holder, proposal) do
          {:ok, _replacement} ->
            entry(holder, cap, :would_sign, event_id: event_id)

          {:error, reason} ->
            entry(holder, cap, :quarantined, reason: {:reauthorization_failed, reason})
        end

      {:error, reason} ->
        entry(holder, cap, :quarantined, reason: reason)
    end
  end

  defp classify(%{holder: holder, cap: cap}, _event_streamer, _issue) do
    entry(holder, cap, :quarantined, reason: :unsupported_candidate_shape)
  end

  defp authoritative_event(events, holder, %Capability{} = candidate) when is_list(events) do
    events
    |> Enum.reduce_while({:ok, %{active: nil, revoked?: false, superseded?: false}}, fn event,
                                                                                        {:ok,
                                                                                         state} ->
      case lifecycle_event(event, holder) do
        :ignore ->
          {:cont, {:ok, state}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        {:ok, :grant, event_cap, event_id} ->
          if same_identity?(candidate, event_cap) do
            if exact_grant_source?(candidate, event_cap, holder) do
              replay = %{
                event_id: event_id,
                issuer: event_cap.granted_by,
                proposal: %{event_cap | signature: nil, key_id: nil, grantee_uri: nil}
              }

              {:cont, {:ok, %{active: replay, revoked?: false, superseded?: false}}}
            else
              # A later grant of the same capability identity replaces the
              # prior slice value. Its source must be exact before it can be
              # reauthorized; otherwise the candidate is stale, not eligible.
              if not is_nil(state.active) do
                {:cont, {:ok, %{active: nil, revoked?: false, superseded?: true}}}
              else
                {:cont, {:ok, state}}
              end
            end
          else
            {:cont, {:ok, state}}
          end

        {:ok, :revoke, event_cap, _event_id} ->
          if not is_nil(state.active) and relevant_revocation?(candidate, event_cap) do
            {:cont, {:ok, %{active: nil, revoked?: true}}}
          else
            {:cont, {:ok, state}}
          end
      end
    end)
    |> finalize_lifecycle()
  end

  defp authoritative_event(_events, _holder, _candidate),
    do: {:error, :malformed_authoritative_grant_event}

  defp finalize_lifecycle({:error, _reason} = error), do: error
  defp finalize_lifecycle({:ok, %{active: replay}}) when not is_nil(replay), do: {:ok, replay}
  defp finalize_lifecycle({:ok, %{revoked?: true}}), do: {:error, :authoritative_grant_revoked}

  defp finalize_lifecycle({:ok, %{superseded?: true}}),
    do: {:error, :authoritative_grant_superseded}

  defp finalize_lifecycle({:ok, _state}), do: {:error, :missing_authoritative_grant_event}

  defp lifecycle_event(%{event_name: event_name}, _holder)
       when event_name not in ["cap_granted", :cap_granted, "cap_revoked", :cap_revoked],
       do: :ignore

  defp lifecycle_event(%{event_name: event_name, payload: payload} = event, holder)
       when event_name in ["cap_granted", :cap_granted, "cap_revoked", :cap_revoked] and
              is_map(payload) do
    with {:ok, target_uri} <- fetch_target_uri(payload),
         {:ok, event_cap} <- fetch_event_cap(payload) do
      if same_uri?(target_uri, holder) and event_grantee_matches_holder?(event_cap, holder) do
        {:ok, event_kind(event_name), event_cap, Map.get(event, :event_id)}
      else
        :ignore
      end
    else
      _ -> {:error, :malformed_authoritative_grant_event}
    end
  end

  defp lifecycle_event(%{event_name: event_name}, _holder)
       when event_name in ["cap_granted", :cap_granted, "cap_revoked", :cap_revoked],
       do: {:error, :malformed_authoritative_grant_event}

  defp lifecycle_event(%{payload: _payload}, _holder),
    do: {:error, :malformed_authoritative_grant_event}

  defp lifecycle_event(_event, _holder), do: :ignore

  defp event_kind(event_name) when event_name in ["cap_granted", :cap_granted], do: :grant
  defp event_kind(event_name) when event_name in ["cap_revoked", :cap_revoked], do: :revoke

  defp fetch_target_uri(%{"target_uri" => uri}) when is_binary(uri), do: parse_uri(uri)
  defp fetch_target_uri(_payload), do: {:error, :missing_target_uri}

  defp fetch_event_cap(%{"cap" => cap}) when is_map(cap) do
    if event_cap_shape?(cap) do
      try do
        decoded = Capability.from_map(cap)

        if canonical_event_cap?(cap, decoded) do
          {:ok, decoded}
        else
          {:error, :invalid_cap_payload}
        end
      rescue
        _error in [ArgumentError, FunctionClauseError, Protocol.UndefinedError] ->
          {:error, :invalid_cap_payload}
      end
    else
      {:error, :invalid_cap_payload}
    end
  end

  defp fetch_event_cap(_payload), do: {:error, :missing_cap_payload}

  defp event_cap_shape?(cap) do
    Enum.all?(Map.keys(cap), &(&1 in @cap_fields)) and
      Enum.all?(@required_cap_fields, &is_binary(Map.get(cap, &1))) and
      optional_event_fields_valid?(cap)
  end

  defp optional_event_fields_valid?(cap) do
    optional_string_or_nil?(cap, "signature") and
      optional_string_or_nil?(cap, "key_id") and
      optional_string_or_nil?(cap, "grantee_uri")
  end

  defp optional_string_or_nil?(cap, key) do
    case Map.fetch(cap, key) do
      :error -> true
      {:ok, value} -> is_nil(value) or is_binary(value)
    end
  end

  defp canonical_event_cap?(event_cap, decoded) do
    canonical = Capability.to_map(decoded)

    Enum.all?(event_cap, fn {key, value} ->
      Map.get(canonical, key) == value
    end)
  end

  defp exact_grant_source?(%Capability{} = candidate, %Capability{} = event_cap, holder) do
    with %URI{} = candidate_issuer <- candidate.granted_by,
         %DateTime{} = candidate_granted_at <- candidate.granted_at,
         %URI{} = event_issuer <- event_cap.granted_by,
         %DateTime{} = event_granted_at <- event_cap.granted_at do
      Capability.identity_key(event_cap) == Capability.identity_key(candidate) and
        same_uri?(event_issuer, candidate_issuer) and
        DateTime.compare(event_granted_at, candidate_granted_at) == :eq and
        event_grantee_matches_holder?(event_cap, holder)
    else
      _ -> false
    end
  end

  defp exact_grant_source?(_candidate, _event_cap, _holder), do: false

  defp relevant_revocation?(candidate, event_cap) do
    same_identity?(candidate, event_cap)
  end

  defp same_identity?(left, right),
    do: Capability.identity_key(left) == Capability.identity_key(right)

  defp event_grantee_matches_holder?(%Capability{grantee_uri: nil}, _holder), do: true

  defp event_grantee_matches_holder?(%Capability{grantee_uri: %URI{} = grantee_uri}, holder),
    do: same_uri?(grantee_uri, holder)

  defp event_grantee_matches_holder?(_event_cap, _holder), do: false

  defp parse_uri(uri) when is_binary(uri) do
    {:ok, Ezagent.URI.new!(uri)}
  rescue
    ArgumentError -> {:error, :invalid_uri}
  end

  defp same_uri?(%URI{} = left, %URI{} = right) do
    Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
  end

  defp entry(holder, cap, status, opts) do
    %{
      holder: holder,
      identity_key: Capability.identity_key(cap),
      status: status
    }
    |> maybe_put(:reason, Keyword.get(opts, :reason))
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp report(entries) do
    %{
      scanned: length(entries),
      would_sign: Enum.count(entries, &(&1.status == :would_sign)),
      quarantined: Enum.count(entries, &(&1.status == :quarantined)),
      skipped: Enum.count(entries, &(&1.status == :skipped)),
      entries: entries
    }
  end
end

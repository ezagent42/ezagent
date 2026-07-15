defmodule Ezagent.Identity.CapSigningAudit do
  @moduledoc """
  Read-only four-source audit for the capability-signing drain.

  Signedness is classified only by `Ezagent.Cap.signed_and_valid?/2`. The
  dual-read acceptance predicate `verify_for/2` is deliberately not used.
  """

  alias Ezagent.Capability
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Identity.{CapQuarantine, CapReconciler, RecipeCapBinding}
  alias EzagentCore.Repo

  @sources [:users_caps_json, :kind_snapshots, :recipe_cap_bindings]

  @type report :: %{
          totals: %{
            signed: non_neg_integer(),
            unsigned_authorizer: non_neg_integer(),
            sentinel_excluded: non_neg_integer(),
            open_quarantined: non_neg_integer()
          },
          unsigned_by_class: %{optional(atom()) => pos_integer()},
          unsigned_by_source: %{optional(atom()) => pos_integer()},
          open_quarantine_by_reason: %{optional(String.t()) => pos_integer()}
        }

  @doc "Run the read-only audit against the configured durable database."
  @spec scan() :: report()
  def scan do
    scan_entries(collect_entries(), Ezagent.Cap.ReissuePolicy.Registry.policies())
  end

  @doc false
  @spec collect_entries() :: map()
  def collect_entries do
    %{
      users_caps_json: collect_users(),
      kind_snapshots: collect_snapshots(),
      recipe_cap_bindings: collect_bindings(),
      cap_quarantine: Repo.all(CapQuarantine)
    }
  end

  @doc false
  @spec scan_entries(map(), [module()]) :: report()
  def scan_entries(entries, policies) when is_map(entries) and is_list(policies) do
    report = empty_report()

    report =
      Enum.reduce(@sources, report, fn source, acc ->
        entries
        |> Map.get(source, [])
        |> Enum.reduce(acc, &classify_entry(&1, &2, policies))
      end)

    entries
    |> Map.get(:cap_quarantine, [])
    |> Enum.reduce(report, &classify_quarantine/2)
  end

  @doc "True only when strict mode has neither unsigned authorizers nor open quarantine."
  @spec clean?(report()) :: boolean()
  def clean?(%{totals: totals}) do
    totals.unsigned_authorizer == 0 and totals.open_quarantined == 0
  end

  defp empty_report do
    %{
      totals: %{
        signed: 0,
        unsigned_authorizer: 0,
        sentinel_excluded: 0,
        open_quarantined: 0
      },
      unsigned_by_class: %{},
      unsigned_by_source: %{},
      open_quarantine_by_reason: %{}
    }
  end

  defp classify_entry(%{excluded: _reason}, report, _policies) do
    increment_total(report, :sentinel_excluded)
  end

  defp classify_entry(%{error: _reason, source: source}, report, _policies) do
    report
    |> increment_total(:unsigned_authorizer)
    |> increment_map(:unsigned_by_class, :malformed_artifact)
    |> increment_map(:unsigned_by_source, source)
  end

  defp classify_entry(
         %{cap: %Capability{} = cap, holder_uri: %URI{} = holder, source: source},
         report,
         policies
       ) do
    cond do
      sentinel?(cap) ->
        increment_total(report, :sentinel_excluded)

      Ezagent.Cap.signed_and_valid?(cap, holder) ->
        increment_total(report, :signed)

      true ->
        class = unsigned_class(cap, holder, policies)

        report
        |> increment_total(:unsigned_authorizer)
        |> increment_map(:unsigned_by_class, class)
        |> increment_map(:unsigned_by_source, source)
    end
  end

  defp classify_entry(%{source: source}, report, _policies) do
    report
    |> increment_total(:unsigned_authorizer)
    |> increment_map(:unsigned_by_class, :malformed_artifact)
    |> increment_map(:unsigned_by_source, source)
  end

  defp classify_quarantine(%{status: :open, reason: reason}, report) do
    report
    |> increment_total(:open_quarantined)
    |> increment_map(:open_quarantine_by_reason, to_string(reason))
  end

  defp classify_quarantine(_row, report), do: report

  defp unsigned_class(cap, holder, policies) do
    case CapReconciler.plan([cap], holder, policies) do
      %{reissue: [%{class: class}]} -> class
      %{quarantine: [%{class: class}]} -> class
      _plan -> :unknown
    end
  end

  defp sentinel?(%Capability{} = cap) do
    cap.granted_by == :plugin_declared or cap.granted_at == :compile_time
  end

  defp increment_total(report, bucket) do
    update_in(report, [:totals, bucket], &(&1 + 1))
  end

  defp increment_map(report, bucket, key) do
    update_in(report, [bucket], &Map.update(&1, key, 1, fn count -> count + 1 end))
  end

  defp collect_users do
    Ezagent.Users
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      collect_serialized_caps(:users_caps_json, row.uri, decode_json_caps(row.caps_json))
    end)
  end

  defp collect_snapshots do
    KindSnapshot.list_all()
    |> Enum.flat_map(fn row ->
      case KindSnapshot.decode_state(row) do
        {:ok, state} when is_map(state) ->
          case identity_caps(state) do
            :none -> []
            {:ok, caps} -> collect_caps(:kind_snapshots, row.uri, caps)
            {:error, reason} -> [error_entry(:kind_snapshots, row.uri, reason)]
          end

        error ->
          [error_entry(:kind_snapshots, row.uri, {:snapshot_decode_failed, error})]
      end
    end)
  end

  defp collect_bindings do
    RecipeCapBinding
    |> Repo.all()
    |> Enum.flat_map(fn binding ->
      excluded = if binding.tombstoned_at, do: :tombstoned_binding, else: nil

      binding.artifacts
      |> binding_caps()
      |> case do
        {:ok, caps} -> collect_caps(:recipe_cap_bindings, binding.agent_uri, caps, excluded)
        {:error, reason} -> [error_entry(:recipe_cap_bindings, binding.agent_uri, reason)]
      end
    end)
  end

  defp decode_json_caps(nil), do: {:ok, []}
  defp decode_json_caps(""), do: {:ok, []}

  defp decode_json_caps(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, caps} when is_list(caps) -> {:ok, caps}
      other -> {:error, {:invalid_caps_json, other}}
    end
  end

  defp identity_caps(state) do
    case fetch_key(state, :identity) do
      :error ->
        :none

      {:ok, slice} when is_map(slice) ->
        inner =
          case fetch_key(slice, :state) do
            {:ok, nested} when is_map(nested) -> nested
            _ -> slice
          end

        case fetch_key(inner, :caps) do
          {:ok, caps} when is_list(caps) -> {:ok, caps}
          {:ok, %MapSet{} = caps} -> {:ok, MapSet.to_list(caps)}
          {:ok, other} -> {:error, {:invalid_identity_caps, other}}
          :error -> :none
        end

      {:ok, other} ->
        {:error, {:invalid_identity_slice, other}}
    end
  end

  defp binding_caps(%{"caps" => caps}) when is_list(caps), do: {:ok, caps}
  defp binding_caps(%{caps: caps}) when is_list(caps), do: {:ok, caps}
  defp binding_caps(other), do: {:error, {:invalid_binding_artifacts, other}}

  defp collect_serialized_caps(source, holder, {:ok, caps}),
    do: collect_caps(source, holder, caps)

  defp collect_serialized_caps(source, holder, {:error, reason}),
    do: [error_entry(source, holder, reason)]

  defp collect_caps(source, holder, caps, excluded \\ nil) do
    with {:ok, holder_uri} <- parse_uri(holder) do
      Enum.map(caps, fn serialized ->
        case normalize_cap(serialized) do
          {:ok, cap} ->
            %{source: source, holder_uri: holder_uri, cap: cap}
            |> maybe_exclude(excluded)

          {:error, reason} ->
            error_entry(source, holder, reason)
        end
      end)
    else
      {:error, reason} -> [error_entry(source, holder, reason)]
    end
  end

  defp normalize_cap(%Capability{} = cap), do: {:ok, cap}

  defp normalize_cap(serialized) when is_map(serialized) do
    {:ok, Capability.from_map(serialized)}
  rescue
    error -> {:error, {:invalid_cap, Exception.message(error)}}
  end

  defp normalize_cap(other), do: {:error, {:invalid_cap, other}}

  defp parse_uri(%URI{} = uri), do: {:ok, Ezagent.URI.instance(uri)}

  defp parse_uri(uri) when is_binary(uri) do
    {:ok, uri |> Ezagent.URI.new!() |> Ezagent.URI.instance()}
  rescue
    error -> {:error, {:invalid_holder_uri, Exception.message(error)}}
  end

  defp fetch_key(map, key) do
    case Map.fetch(map, key) do
      :error -> Map.fetch(map, Atom.to_string(key))
      result -> result
    end
  end

  defp maybe_exclude(entry, nil), do: entry
  defp maybe_exclude(entry, reason), do: Map.put(entry, :excluded, reason)

  defp error_entry(source, holder, reason),
    do: %{source: source, holder_uri: holder, error: reason}
end

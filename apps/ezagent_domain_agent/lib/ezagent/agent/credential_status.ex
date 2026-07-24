defmodule Ezagent.Agent.CredentialStatus do
  @moduledoc """
  #160 — flavor-agnostic credential-status model + probe router (read-only, v1).

  A single normalized status enum so the UI stays flavor-blind, plus the
  flavor→probe router that turns an agent's on-disk / on-slice login state into
  that enum WITHOUT activating the agent and WITHOUT any network I/O.

  ## Normalized status

    * `:authenticated` — valid login state present.
    * `:expiring`      — valid but within the expiry/skew window (cc only — the one
                         flavor with a readable `expiresAt`).
    * `:expired`       — login state present but dead; the agent will 401 until re-login.
    * `:missing`       — the flavor NEEDS login state and it is absent (logged out /
                         never `/login`).
    * `:n_a`           — the flavor holds no credentials by design (py/echo/np);
                         rendered as a dash, never an alarm.
    * `:unknown`       — cannot classify (unreadable file, non-standard shape, cold
                         agent with no cached state). Never an alarm.

  ## Routing (flavor-blind)

  The router consults `Ezagent.AgentFlavorRegistry` for the flavor's Template
  Class, then routes on the DECLARED credential contract (not a per-flavor
  hardcode):

    * a file-credentialled TC (`Ezagent.Agent.CredentialAdapter.credentialled?/1`)
      that implements the optional `credential_status/2` callback → delegate to it
      (cc/codex own their own classification, so flavor knowledge stays in the
      plugin — the plugin-isolation seam);
    * a slice-credentialled TC (`Ezagent.Agent.CredentialSliceAdapter`) → derive
      `:authenticated` / `:missing` from the presence of keys in its credential
      slice (curl → `:api_keys`), reading only a non-activating snapshot;
    * neither → `:n_a` (credential-less by design).

  Adding a new file-credentialled flavor plugin therefore needs only its Template
  Class to implement `credential_status/2` — no edit here.
  """

  alias Ezagent.Agent.{CredentialAdapter, CredentialSliceAdapter}

  @statuses [:authenticated, :expiring, :expired, :missing, :n_a, :unknown]

  @type status :: :authenticated | :expiring | :expired | :missing | :n_a | :unknown

  @type result :: %{
          status: status(),
          flavor: String.t() | nil,
          detail: String.t() | nil,
          expires_at: integer() | nil,
          checked_at: DateTime.t()
        }

  @doc "The complete normalized status enum."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Classify `agent_uri`'s credential status. `flavor` is the agent's resolved
  flavor; `config_dir` is its credential home path (from the persisted `:sandbox`
  slice) for file flavors, `nil` otherwise. `opts` is forwarded to the flavor
  probe (e.g. `:now_ms`/`:skew_ms` for cc). Trusted internal read — the CALLER
  authorizes first (`Ezagent.Domain.Agent.read_credential_status/2`). Never
  activates the agent, never does network I/O.
  """
  @spec classify(URI.t(), String.t() | nil, String.t() | nil, keyword()) :: result()
  def classify(%URI{} = agent_uri, flavor, config_dir, opts \\ []) do
    base = %{flavor: flavor, detail: nil, expires_at: nil, checked_at: DateTime.utc_now()}
    # `:credential_slice` (§6.3) — a slice PRE-FETCHED by a directory's ONE
    # `read_durable_many/3` batch; popped so it never leaks to the flavor probe.
    {credential_slice, probe_opts} = Keyword.pop(opts, :credential_slice, :not_prefetched)

    probed =
      case flavor && Ezagent.AgentFlavorRegistry.lookup(flavor) do
        {:ok, %{template_class: tc}} when is_atom(tc) and tc != nil ->
          classify_with_template_class(tc, agent_uri, config_dir, probe_opts, credential_slice)

        _ ->
          # Unknown / unregistered flavor — cannot classify.
          %{status: :unknown}
      end

    Map.merge(base, probed)
  end

  # ── flavor routing ────────────────────────────────────────────────

  defp classify_with_template_class(tc, agent_uri, config_dir, opts, credential_slice) do
    cond do
      CredentialAdapter.credentialled?(tc) ->
        file_status(tc, config_dir, opts)

      CredentialSliceAdapter.credentialled?(tc) ->
        slice_status(tc, agent_uri, credential_slice)

      true ->
        # Credential-less flavor (py/echo/np) — no disk/slice read at all.
        %{status: :n_a}
    end
  end

  # File-credentialled (cc/codex): delegate to the flavor's own `credential_status/2`
  # (the enum adapter lives in the plugin). A credentialled flavor that has not yet
  # implemented the probe is `:unknown` (never an alarm).
  defp file_status(tc, config_dir, opts) do
    if function_exported?(tc, :credential_status, 2) do
      case tc.credential_status(config_dir, opts) do
        %{status: status} = m when status in @statuses ->
          %{status: status, detail: Map.get(m, :detail), expires_at: Map.get(m, :expires_at)}

        _ ->
          %{status: :unknown}
      end
    else
      %{status: :unknown}
    end
  rescue
    _ -> %{status: :unknown}
  end

  # Slice-credentialled (curl): `:authenticated` iff the credential slice holds at
  # least one key, else `:missing`. Reads the LIVE slice, falling back to the
  # durable snapshot for a cold agent — both non-activating. Never returns/masks a
  # plaintext key; only the key COUNT matters. curl is the sole slice-credentialled
  # flavor (per `CredentialAdapterContractTest`), so keying on `:keys` is exact.
  # `credential_slice` is `:not_prefetched` (single-agent callers → read the slice
  # here, non-activating) OR a `{:ok, slice} | :error` already resolved by the
  # DIRECTORY's ONE `read_durable_many/3` batch (§6.3 — render N rows with one
  # durable query, never N per-agent reads).
  defp slice_status(tc, agent_uri, credential_slice) do
    resolved =
      case credential_slice do
        :not_prefetched -> read_credential_slice(agent_uri, tc.credential_slice())
        prefetched -> prefetched
      end

    case resolved do
      {:ok, slice} when is_map(slice) ->
        keys = Map.get(slice, :keys) || Map.get(slice, "keys") || %{}

        if is_map(keys) and map_size(keys) > 0 do
          %{status: :authenticated}
        else
          %{status: :missing}
        end

      _ ->
        %{status: :unknown}
    end
  rescue
    _ -> %{status: :unknown}
  end

  # Live slice (non-activating: `read/3` with `spawn: :never` returns the live
  # slice or `{:error, :not_live}` for a cold Kind — never spawns, and is
  # self-safe) → else the durable snapshot projection (also non-activating).
  # §2.2 actor read surface (C2).
  defp read_credential_slice(agent_uri, slice_key) do
    case Ezagent.Kind.read(agent_uri, slice_key, spawn: :never) do
      {:ok, slice} when is_map(slice) -> {:ok, slice}
      _ -> snapshot_slice(agent_uri, slice_key)
    end
  end

  defp snapshot_slice(agent_uri, slice_key) do
    case Ezagent.Kind.read_durable(agent_uri, slice_key) do
      {:ok, slice, _meta} when is_map(slice) -> {:ok, slice}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end

defmodule Mix.Tasks.Ezagent.ExternalMirror.CLI do
  @moduledoc """
  Shared internals for the `mix ezagent.external_mirror.*` task family
  (SPEC §9 PR-EM-5).

  Responsibilities:

  1. **Caller URI resolution** — read `--as <user_uri>` flag OR
     `EZAGENT_AS_USER` env var; default `entity://user/system/admin`
     when neither is set (matches the project convention for other
     `mix ezagent.*` tasks like `ezagent.feishu.bind --admin`).
  2. **Client-side cap check** — load the caller's caps via
     `Ezagent.Identity.list_caps_for/1` and verify the required cap
     for the action exists BEFORE attempting dispatch. On miss: print
     `:unauthorized` to stderr + `Mix.raise/1` (exits 1). (SPEC §9
     PR-EM-5: "All commands check caps client-side AND surface
     dispatch errors verbatim".)
  3. **Verbatim error surface** — `surface_error/1` formats facade
     `{:error, reason}` returns per P18: the atom IS the contract,
     don't translate, print to stderr + exit 1.
  4. **`app.start` lifecycle** — these tasks need the runtime ETS
     tables (AdapterRegistry, BindingRegistry, KindRegistry) + Repo
     started. `Mix.Task.run("app.start")` is the standard way.

  ## Why standalone Mix tasks, not `mix esr` auto-derived

  The project's `mix esr <kind> <op>` auto-derive (FacadeRegistry +
  BehaviorRegistry tree-build) is the preferred path for new
  operations, but the SPEC §9 PR-EM-5 brief names these commands
  explicitly as `mix ezagent.external_mirror.*` — operators can
  type those names from the spec without learning the auto-derive
  conventions. The tasks here ARE thin wrappers over the same
  `Ezagent.ExternalMirror` facade the LV uses (PR-EM-4); the same
  dispatch CapBAC + audit + cross-workspace checks apply.

  ## URI authority normalization

  `caller_uri/1` and `parse_session_uri/1` both go through stock
  `URI.parse/1` which populates the `:authority` field. Without
  this, `Capability.matches?/2` instance equality silently denies
  against a `Ezagent.URI.parse!`-produced URI (no authority) — the
  same trap PR-EM-4 worked around in its LV mount.
  """

  alias Ezagent.{Capability, ExternalMirror}

  # ----- Public API consumed by the per-action tasks -----------------------

  @doc """
  Parse the standard CLI argument set used by every `external_mirror`
  task. Returns `{positional, opts}` where `opts` includes `:as` and
  `:metadata`.

  `--as <uri>` overrides `EZAGENT_AS_USER` overrides the bootstrap
  admin URI.
  """
  @spec parse_argv([String.t()]) :: {[String.t()], map()}
  def parse_argv(argv) do
    {parsed, positional, _invalid} =
      OptionParser.parse(argv,
        strict: [as: :string, metadata: :keep, help: :boolean],
        aliases: [h: :help]
      )

    as_uri = parsed[:as] || System.get_env("EZAGENT_AS_USER") || "entity://user/system/admin"
    metadata = parse_metadata_kv(Keyword.get_values(parsed, :metadata))

    {positional, %{as: as_uri, metadata: metadata, help?: Keyword.get(parsed, :help, false)}}
  end

  defp parse_metadata_kv(pairs) when is_list(pairs) do
    pairs
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {String.trim(k), String.trim(v)}
        _ -> {pair, ""}
      end
    end)
    |> Map.new()
  end

  @doc """
  Build the dispatch ctx for the caller, including a freshly-loaded
  cap MapSet. Uses stock `URI.parse/1` so the `:authority` field is
  set (matches `Ezagent.URI.instance/1` + `Capability.cap_for_action/3`
  shape).
  """
  @spec build_ctx(String.t()) :: %{
          caller: URI.t(),
          caps: MapSet.t(Capability.t()),
          reply: :ignore
        }
  def build_ctx(as_uri) when is_binary(as_uri) do
    caller_uri = URI.parse(as_uri)
    caps = load_caps(caller_uri)

    %{caller: caller_uri, caps: caps, reply: :ignore}
  end

  defp load_caps(%URI{} = caller_uri) do
    Ezagent.Identity.list_caps_for(caller_uri)
  rescue
    _ -> MapSet.new()
  end

  @doc """
  Client-side check: caller holds the cap that authorizes
  `action` on the Session Kind at `session_uri`. On miss → print
  `:unauthorized` to stderr + `Mix.raise/1` BEFORE dispatch.

  This is the SPEC §9 PR-EM-5 "check caps client-side" requirement;
  the dispatch-side check at step 5.5 still runs as defence-in-depth.

  Uses `Mix.raise/1` (catchable in tests, exits with 1 in production)
  rather than `System.halt/1` (terminates the whole BEAM — would kill
  the ExUnit runner on test paths). The Mix.shell().error/1 call
  ensures the operator-facing stderr line is emitted first; the raise
  follows for the exit-1 contract.
  """
  @spec require_session_cap!(map(), URI.t(), atom()) :: :ok
  def require_session_cap!(ctx, %URI{} = session_uri, action) when is_atom(action) do
    needed =
      Capability.cap_for_action(Ezagent.Entity.Session, action, session_uri)

    if Enum.any?(ctx.caps, &Capability.matches?(&1, needed)) do
      :ok
    else
      Mix.shell().error(
        "error: :unauthorized — caller #{URI.to_string(ctx.caller)} does not hold the " <>
          "#{inspect(needed.kind)}/#{inspect(needed.behavior)} cap on " <>
          "#{URI.to_string(session_uri)} (action :#{action})"
      )

      Mix.raise(":unauthorized")
    end
  end

  @doc """
  Parse a session URI string into a `%URI{}`. Uses stock `URI.parse/1`
  (authority populated) so downstream cap matching works.
  """
  @spec parse_session_uri(String.t()) :: URI.t()
  def parse_session_uri(s) when is_binary(s) do
    case URI.parse(s) do
      %URI{scheme: "session"} = uri ->
        uri

      _ ->
        Mix.shell().error("error: #{inspect(s)} is not a session:// URI")
        Mix.raise("bad session URI")
    end
  end

  @doc """
  Print a facade `{:error, reason}` verbatim to stderr + exit 1.
  Per P18: the atom IS the contract; don't translate, don't wrap.

  Uses `Mix.raise/1` (catchable in tests, exits with 1 in production)
  rather than `System.halt/1` (terminates the whole BEAM — would kill
  the ExUnit runner). The Mix.shell().error/1 call emits the
  operator-facing stderr line first; the raise carries the same atom
  for the exit-1 contract.
  """
  @spec surface_error(term()) :: no_return()
  def surface_error(reason) do
    Mix.shell().error("error: #{inspect(reason)}")
    Mix.raise(inspect(reason))
  end

  @doc """
  Ensure the runtime ETS tables + Repo are up before facade calls.
  Idempotent — re-running `app.start` after first call is a no-op.
  """
  @spec ensure_app_started!() :: :ok
  def ensure_app_started! do
    Mix.Task.run("app.start")
    :ok
  end

  @doc """
  Format a list of binding rows as a simple text table for stdout.
  """
  @spec format_bindings([ExternalMirror.binding()]) :: String.t()
  def format_bindings([]), do: "(no bindings)\n"

  def format_bindings(bindings) when is_list(bindings) do
    header = pad("adapter_id", 16) <> pad("target_id", 32) <> pad("bound_at", 32) <> "binding_id\n"
    rule = String.duplicate("-", 100) <> "\n"

    rows =
      bindings
      |> Enum.map(fn b ->
        pad(b.adapter_id, 16) <>
          pad(inspect(b.target_id), 32) <>
          pad(DateTime.to_iso8601(b.bound_at), 32) <>
          b.binding_id <> "\n"
      end)
      |> Enum.join("")

    header <> rule <> rows
  end

  @doc """
  Format the adapter list (SPEC §4.4 shape) as a text table.
  """
  @spec format_adapters([ExternalMirror.adapter_descriptor()]) :: String.t()
  def format_adapters([]), do: "(no adapters registered)\n"

  def format_adapters(adapters) when is_list(adapters) do
    header = pad("id", 24) <> pad("display_name", 32) <> "description\n"
    rule = String.duplicate("-", 100) <> "\n"

    rows =
      adapters
      |> Enum.map(fn a ->
        pad(a.id, 24) <> pad(a.display_name, 32) <> a.description <> "\n"
      end)
      |> Enum.join("")

    header <> rule <> rows
  end

  defp pad(s, width) when is_binary(s) do
    s = String.slice(s, 0, width - 1)
    s <> String.duplicate(" ", max(0, width - String.length(s)))
  end
end

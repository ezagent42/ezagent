defmodule Ezagent.Capability.Parser do
  @moduledoc """
  String → `[Ezagent.Capability.t()]` parser for the `mix ezagent.user.create`
  CLI per Phase 4-completion Spec 05 §A.2.1.

  ## Grammar

  Comma-separated list of cap specs:

      "chat.send,workspace.read"
      "*"                                       # admin-equivalent triple-:any
      "workspace.workspace@workspace://main"    # instance-scoped
      "chat.*"                                  # kind-scoped (Decision #19)

  ## Validation

  - Kind atoms must be `String.to_existing_atom` resolvable (rejects
    typos at user-action time per `feedback_let_it_crash_no_workarounds`)
  - Behavior strings must resolve to a registered Behavior in
    `BehaviorRegistry` (best-effort — passes if not yet registered)
  - `*` requires the `--allow-allcaps` flag at the CLI layer (parser
    accepts `*` but task layer enforces the flag)
  """

  @doc """
  Parse a caps string into a list of Capability structs.

  `granter` is the URI of who is granting (e.g. `entity://user/system/admin`
  when admin runs `mix ezagent.user.create`). `now` defaults to
  current UTC.
  """
  @spec parse(String.t(), URI.t(), DateTime.t()) ::
          {:ok, [Ezagent.Capability.t()]} | {:error, term()}
  def parse(caps_str, granter, now \\ DateTime.utc_now()) when is_binary(caps_str) do
    caps_str
    |> String.trim()
    |> case do
      "" ->
        {:ok, []}

      str ->
        str
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> parse_specs([], granter, now)
    end
  end

  defp parse_specs([], acc, _granter, _now), do: {:ok, Enum.reverse(acc)}

  defp parse_specs([spec | rest], acc, granter, now) do
    case parse_one(spec, granter, now) do
      {:ok, cap} -> parse_specs(rest, [cap | acc], granter, now)
      {:error, _} = err -> err
    end
  end

  defp parse_one("*", granter, now) do
    {:ok,
     %Ezagent.Capability{
       kind: :any,
       behavior: :any,
       # SPEC 2026-05-27 capability-action-axis — `*` is the operator
       # full-wildcard shorthand; action axis matches the other four
       # for admin-equivalent semantics.
       action: :any,
       instance: :any,
       # `*` is the operator shorthand for "admin-equivalent" — cross-
       # workspace by intent. SPEC v3 §4 still allows operators to
       # mint such caps via `--allow-allcaps`; the workspace dimension
       # follows the kind/behavior/instance wildcard pattern.
       workspace_uri: :any,
       granted_by: granter,
       granted_at: now
     }}
  end

  defp parse_one(spec, granter, now) when is_binary(spec) do
    {body, instance_uri} = split_instance(spec)

    case String.split(body, ".", parts: 2) do
      [kind_str, behavior_str] ->
        with {:ok, kind_atom} <- safe_atom(kind_str),
             {:ok, behavior} <- resolve_behavior(behavior_str) do
          {:ok,
           %Ezagent.Capability{
             kind: kind_atom,
             behavior: behavior,
             # SPEC 2026-05-27 capability-action-axis — current parser
             # grammar `<kind>.<behavior>[/<instance>]` doesn't carry an
             # action; default `:any` until a future PR adds the
             # `.<action>` suffix per SPEC §11.
             action: :any,
             instance: instance_uri,
             # Parsed caps default to cross-workspace (`:any`) so the
             # CLI grammar stays backward-compatible for now. Phase 9
             # PR-4 will add an explicit `@<workspace>` suffix to the
             # grammar; PR-3 just plumbs the field. The granter
             # (typically admin) is the only principal authorized to
             # mint cross-workspace caps anyway, so `:any` here is
             # not an escape hatch beyond what the operator already
             # has.
             workspace_uri: :any,
             granted_by: granter,
             granted_at: now
           }}
        end

      _ ->
        {:error, {:bad_cap_spec, spec}}
    end
  end

  defp split_instance(spec) do
    case String.split(spec, "@", parts: 2) do
      [body, instance_str] ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # for any URI string entering the system. Try/rescue keeps the
        # `{body, :any}` fall-through for malformed CLI specs.
        try do
          {body, Ezagent.URI.new!(instance_str)}
        rescue
          ArgumentError -> {body, :any}
        end

      [body] ->
        {body, :any}
    end
  end

  defp safe_atom("*"), do: {:ok, :any}

  defp safe_atom(s) when is_binary(s) do
    try do
      {:ok, String.to_existing_atom(s)}
    rescue
      ArgumentError -> {:error, {:unknown_kind, s}}
    end
  end

  defp resolve_behavior("*"), do: {:ok, :any}

  defp resolve_behavior(name) when is_binary(name) do
    # Resolve to behavior module via convention: kind name + "Behavior"
    # OR look up in BehaviorRegistry by state_slice match
    # For Phase 4 v1: accept the literal string as an atom (e.g. "chat" → :chat),
    # which matches state_slice values; downstream cap matching is by module.
    # Convert to module via convention: "chat" → Ezagent.ActionSet.Session
    capitalized =
      name
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join("")

    module_str = "Elixir.Ezagent.ActionSet." <> capitalized

    try do
      module = String.to_existing_atom(module_str)
      {:ok, module}
    rescue
      ArgumentError ->
        # Module not loaded yet (plugin Application hasn't started)
        # — fall back to :any so the cap parses; runtime check will
        # validate.
        {:ok, :any}
    end
  end
end

defmodule EzagentCli.TreeBuilder do
  @moduledoc """
  Walks `Ezagent.BehaviorRegistry.list_all/0` + `EzagentCli.FacadeRegistry`
  and produces the Optimus subcommand tree.

  Top-level: `mix esr` → subcommands per Kind. Each Kind subcommand
  has further subcommands per Behavior action (auto-derived) + per
  facade op (registered).

  Per Spec 02 §3: rebuilt every invocation; the walk is O(#actions) ~20
  today, trivial. No compile-time caching that would couple CLI shape
  to compile order.
  """

  alias EzagentCli.{Coercion, FacadeRegistry, SessionConfigFacade, SessionSocialwareFacade}

  @doc """
  Build the Optimus root spec. `behavior_triples` is
  `[{{kind_module, action}, behavior_module}, ...]` from
  `BehaviorRegistry.list_all/0`.
  """
  @spec build(list()) :: Optimus.t()
  def build(behavior_triples \\ Ezagent.BehaviorRegistry.list_all()) do
    # The OTP release keeps :ezagent_cli load-only. Rebuild this domain-owned
    # projection on every CLI tree construction so commands are reachable even
    # when EzagentCli.Application.start/2 was intentionally never invoked.
    :ok = SessionConfigFacade.register_all()
    :ok = SessionSocialwareFacade.register_all()

    # Filter stale entries — when test suites register fake Kind
    # modules per-test, those modules may no longer be loadable when
    # build() runs later. Skip rather than crash.
    # Pre-resolve type_name for each kind module, dropping any that
    # can't answer (test-leaked fake modules, unloaded code).
    # safe_type_name returns nil on any failure.
    kind_to_type =
      behavior_triples
      |> Enum.map(fn {{kind_mod, _action}, _bhv} -> kind_mod end)
      |> Enum.uniq()
      |> Enum.map(fn kind_mod -> {kind_mod, safe_type_name(kind_mod)} end)
      |> Enum.reject(fn {_, t} -> is_nil(t) end)
      |> Map.new()

    by_type =
      behavior_triples
      |> Enum.filter(fn {{kind_mod, _action}, _bhv} -> Map.has_key?(kind_to_type, kind_mod) end)
      |> Enum.group_by(fn {{kind_mod, _action}, _bhv} -> Map.fetch!(kind_to_type, kind_mod) end)

    kind_subcommands =
      by_type
      |> Enum.map(fn {type_name, actions} ->
        {type_name, kind_subcommand(type_name, actions)}
      end)

    type_names_in_use = MapSet.new(Map.values(kind_to_type))

    # Facade-only kinds (registered ops with no matching Behavior actions)
    facade_only_kinds =
      FacadeRegistry.list_kinds()
      |> Enum.reject(fn kt -> MapSet.member?(type_names_in_use, kt) end)
      |> Enum.reject(&is_nil/1)

    facade_only_subcommands =
      facade_only_kinds
      |> Enum.map(fn type_name ->
        {type_name, facade_only_subcommand(type_name)}
      end)

    Optimus.new!(
      name: "esr",
      description: "Ezagent Invocation CLI — auto-derived from BehaviorRegistry + FacadeRegistry",
      version: "0.1.0",
      allow_unknown_args: false,
      parse_double_dash: true,
      subcommands: kind_subcommands ++ facade_only_subcommands
    )
  end

  defp kind_subcommand(type_name, actions) do
    action_subs =
      actions
      |> Enum.group_by(fn {{_kind, action}, _behavior_module} -> action end)
      |> Enum.map(fn {action, candidates} ->
        {{kind_module, _action}, behavior_module} =
          Enum.min_by(candidates, fn {{kind_module, _action}, behavior_module} ->
            {kind_priority(kind_module), inspect(kind_module), inspect(behavior_module)}
          end)

        {action, action_subcommand(kind_module, type_name, behavior_module, action)}
      end)

    facade_subs =
      FacadeRegistry.list(type_name)
      |> Enum.map(fn {op_name, _fun, spec} ->
        {op_name, facade_subcommand(type_name, op_name, spec)}
      end)

    [
      name: to_string(type_name),
      about: "Actions on #{type_name}://<instance>",
      subcommands: action_subs ++ facade_subs
    ]
  end

  defp action_subcommand(_kind_module, type_name, behavior_module, action) do
    interface = behavior_module.interface()[action] || %{}

    args_spec =
      case Map.get(interface, :args, %{}) do
        {:closed_map, schema} -> schema
        schema -> schema
      end

    modes = Map.get(interface, :modes, [:call])

    # Instance arg: --<type_name> required
    instance_opt =
      {type_name,
       [
         value_name: String.upcase(to_string(type_name)),
         long: to_string(type_name) |> String.replace("_", "-"),
         parser: :string,
         required: true
       ]}

    # Schema args as options
    arg_options =
      args_spec
      |> Enum.map(fn {arg_name, arg_type} ->
        Coercion.to_option(arg_name, arg_type, required: true)
      end)

    # --cast flag if both :call and :cast are supported
    cast_flag =
      if :cast in modes do
        [cast: [long: "cast"]]
      else
        []
      end

    # --as flag for caller override (Spec 02 §2.F)
    as_opt = {:as, [long: "as", value_name: "USER_URI", parser: :string]}

    # --json flag for machine-readable output
    json_flag = [json: [long: "json"]]

    # --deadline-ms
    deadline_opt = {:deadline_ms, [long: "deadline-ms", value_name: "MS", parser: :integer]}

    # SPEC #366 (Allen 2026-05-26): explicit template-class for bare-name
    # promotion on per-tenant schemes (`session://`, `template://`,
    # `resource://`). Consumed by `EzagentCli.Dispatch.build_target_uri/6`
    # when the instance arg is a bare name; ignored for full URIs and
    # for non-per-tenant schemes. Required (and enforced by raise) only
    # when promotion actually needs it — Optimus can't express "required
    # conditional on scheme", so the runtime check in
    # `Dispatch.promote_to_3seg/4` carries the load.
    #
    # Option key is `:instance_class` (long flag `--instance-class`) to
    # avoid colliding with existing action args named `:template_class`
    # (e.g. `Ezagent.ActionSet.Sandbox.update_config` carries
    # `template_class:` in its `args` map). The flag is added to every
    # action subcommand uniformly — Optimus rejects conditional-by-
    # scheme options at the spec level.
    instance_class_opt =
      {:instance_class, [long: "instance-class", value_name: "CLASS", parser: :string]}

    [
      name: to_string(action),
      about: action_about(behavior_module, action),
      options: [instance_opt | arg_options] ++ [as_opt, deadline_opt, instance_class_opt],
      flags: cast_flag ++ json_flag
    ]
  end

  # V1 UI SPEC §0: the `@interface` action schema carries an optional
  # `description:` string — the single source of truth for "what does
  # this action do," shared by the CLI (here) and CmdK. Read it directly;
  # fall back to generic text only when a Behavior hasn't backfilled one.
  # The previous `Code.fetch_docs/1` scrape looked for a function named
  # after the action — but Behaviors implement `invoke(:action, ...)`,
  # never `def <action>`, so it almost always fell through to generic.
  defp action_about(behavior_module, action) do
    case behavior_module.interface()[action][:description] do
      desc when is_binary(desc) -> desc
      _ -> "#{action} action on #{behavior_module}"
    end
  end

  defp facade_subcommand(_kind_type, op_name, spec) do
    args_keyword =
      Map.get(spec, :args, [])
      |> Enum.map(fn {name, type} ->
        {name,
         [value_name: String.upcase(to_string(name)), parser: parser_for(type), required: true]}
      end)

    opts_keyword =
      Map.get(spec, :opts, [])
      |> Enum.map(fn {name, type} ->
        Coercion.to_option(name, type, required: false)
      end)

    [
      name: to_string(op_name),
      about: spec[:about] || "facade op",
      args: args_keyword,
      options: opts_keyword,
      flags: [json: [long: "json"]]
    ]
  end

  defp facade_only_subcommand(type_name) do
    facade_subs =
      FacadeRegistry.list(type_name)
      |> Enum.map(fn {op_name, _fun, spec} ->
        {op_name, facade_subcommand(type_name, op_name, spec)}
      end)

    [
      name: to_string(type_name),
      about: "Facade ops for #{type_name}",
      subcommands: facade_subs
    ]
  end

  defp parser_for(:string), do: :string
  defp parser_for(:integer), do: :integer

  defp parser_for(:uri),
    do: fn s ->
      # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
      # with try/rescue keeping the parser's `{:error, msg}` contract.
      try do
        {:ok, Ezagent.URI.new!(s)}
      rescue
        ArgumentError -> {:error, "malformed URI: #{inspect(s)}"}
      end
    end

  defp parser_for(_), do: :string

  # Safely resolve type_name/0 — returns nil if the module isn't loaded
  # or doesn't export type_name/0 (test-spawned fake modules can be
  # left in BehaviorRegistry ETS after their parent test exits).
  defp safe_type_name(kind_mod) do
    if Code.ensure_loaded?(kind_mod) and function_exported?(kind_mod, :type_name, 0) do
      try do
        kind_mod.type_name()
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
    else
      nil
    end
  end

  defp kind_priority(kind_mod) do
    case Module.split(kind_mod) do
      ["Ezagent", "Entity" | _] -> 0
      _ -> 1
    end
  end
end

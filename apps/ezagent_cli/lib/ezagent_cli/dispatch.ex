defmodule EzagentCli.Dispatch do
  @moduledoc """
  Build `%Ezagent.Invocation{}` from parsed Optimus result and dispatch.

  Constructs target URI from the `--<kind_type>` instance arg, threads
  caps from caller's Identity slice (or admin default), waits on the
  caller mailbox for `:call` mode.
  """

  alias Ezagent.Invocation

  @default_deadline_ms 5000

  @doc """
  Dispatch an auto-derived action.

  `kind_module` + `behavior_module` + `action` identify which action.
  `parsed` is the Optimus `%{options:, flags:, args:}` for the subcommand.
  """
  @spec run_action(module(), module(), atom(), map()) :: {:ok, term()} | {:error, term()}
  def run_action(kind_module, behavior_module, action, parsed) do
    type_name = kind_module.type_name()
    options = Map.get(parsed, :options, %{})
    flags = Map.get(parsed, :flags, %{})

    # Build URI
    case Map.get(options, type_name) do
      nil ->
        {:error, {:missing_instance_arg, type_name}}

      instance ->
        # Extract action args (everything except --<type_name>, --as,
        # --deadline-ms, --instance-class). `:instance_class` is consumed
        # by `build_target_uri/6` for bare-name promotion (SPEC #366);
        # it is NOT an action arg.
        reserved = MapSet.new([type_name, :as, :deadline_ms, :instance_class])
        action_args = Map.drop(options, MapSet.to_list(reserved))

        # Determine mode
        mode =
          if Map.get(flags, :cast, false) do
            :cast
          else
            interface = behavior_module.interface()[action] || %{}
            modes = Map.get(interface, :modes, [:call])

            cond do
              :call in modes -> :call
              :cast in modes -> :cast
              true -> :call
            end
          end

        # Caller + caps — codex CLI/GUI audit HIGH-1: derive_caller
        # may refuse with {:error, :no_identity | :as_not_allowed |
        # {:bad_as_uri, _}} when no token + no valid --as flag. We
        # let those error tuples propagate so the CLI exits with a
        # clear message instead of silently elevating to admin.
        case derive_caller(options) do
          {%URI{} = caller_uri, caps} ->
            # SPEC #324: bare-name `--session foo` promotion derives
            # workspace structurally from caller_uri instead of the
            # legacy silent `"default"` default.
            #
            # SPEC #366 (Allen 2026-05-26): the template-class slot of
            # `session://<workspace>/<class>/<name>` (and `template://`
            # / `resource://`) must also be explicit — `options` flows
            # through to `promote_to_3seg/4` which reads `:instance_class`
            # and raises if absent for bare-name promotions.
            target_uri =
              build_target_uri(
                type_name,
                instance,
                behavior_module,
                action,
                caller_uri,
                options
              )

            deadline_ms = Map.get(options, :deadline_ms) || @default_deadline_ms

            inv = %Invocation{
              target: target_uri,
              mode: mode,
              args: action_args,
              ctx: %{
                caller: caller_uri,
                caps: caps,
                reply: {:caller_inbox, self()},
                deadline_ms: deadline_ms
              },
              origin: :trusted_internal
            }

            do_dispatch(inv, mode, deadline_ms)

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Run a registered facade op by looking it up + calling with parsed args.
  """
  @spec run_facade(atom() | nil, atom(), map()) :: {:ok, term()} | {:error, term()}
  def run_facade(kind_type, op_name, parsed) do
    case EzagentCli.FacadeRegistry.lookup(kind_type, op_name) do
      {:ok, fun, _spec} -> fun.(parsed)
      :error -> {:error, {:no_such_facade, kind_type, op_name}}
    end
  end

  defp build_target_uri(
         type_name,
         instance,
         behavior_module,
         action,
         %URI{} = caller_uri,
         options
       )
       when is_map(options) do
    behavior_seg = behavior_module.state_slice() |> to_string()
    action_qs = "?action=#{behavior_seg}.#{to_string(action)}"

    # Codex PR #356 r1 HIGH fix: if the operator passes a full
    # `entity://user/<workspace>/<name>` (or any other valid full URI)
    # as the instance, use it AS-IS and only append the action query
    # string. Without this, the CLI would build
    # `user://entity://user/...` which is malformed — the User Kind's
    # actual URIs are `entity://<workspace>/user/...`,
    # not `user://...`.
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue: a full Ezagent URI is parsed canonical + action
    # appended; bare instance falls back to scheme-prefix legacy form.
    try do
      parsed_uri = Ezagent.URI.new!(instance)
      Ezagent.URI.new!(URI.to_string(parsed_uri) <> action_qs)
    rescue
      ArgumentError ->
        # Bare name — fall back to legacy scheme = type_name + promote.
        scheme = scheme_for(type_name)
        caller_workspace = workspace_name_from_caller(caller_uri)
        instance_class = Map.get(options, :instance_class)
        promoted_instance = promote_to_3seg(scheme, instance, caller_workspace, instance_class)
        Ezagent.URI.new!("#{scheme}://#{promoted_instance}#{action_qs}")
    end
  end

  # Phase 4 completion: scheme defaults to type_name. Echo overrides
  # by using `entity://agent/` for instances — but for CLI we use type_name
  # consistently. Phase 5+ can add scheme/0 callback on Kind if needed.
  defp scheme_for(type_name), do: to_string(type_name)

  # SPEC #324 rev 3 (Allen 2026-05-26): extract workspace name from
  # caller URI structurally. Per Allen's directive — "如果没有提供 workspace
  # name，应该直接 crash. 现在已经没有了默认 workspace 这个概念" — any
  # non-entity caller raises rather than silently falling through to a
  # "system" workspace. Production callers always carry an entity
  # URI from the CLI bearer-token auth path; non-entity callers are
  # operator-error and must be visible.
  defp workspace_name_from_caller(%URI{scheme: "entity"} = uri) do
    uri
    |> Ezagent.URI.entity_workspace_uri()
    |> Ezagent.URI.name!()
  end

  defp workspace_name_from_caller(other) do
    raise ArgumentError,
          "caller URI is not an entity URI — got #{inspect(other)}. " <>
            "Per SPEC #324 rev 3 / PR #335, there is NO silent default workspace " <>
            "fallback; the caller must carry a structural workspace. Production " <>
            "callers always have an entity URI from CLI bearer-token auth — a " <>
            "non-entity caller indicates a misconfigured token / --as flag."
  end

  # SPEC v3 §3.6 (Phase 9 PR-7) + SPEC #324 — fill in missing
  # workspace/template segments for the unified per-tenant schemes when
  # the operator passed a bare name on the CLI. Workspace is taken from
  # the caller URI structurally rather than the silent `"default"`
  # legacy default.
  #
  # SPEC #366 (Allen 2026-05-26 02:43Z, `feedback_let_it_crash_no_workarounds`):
  # the template/type slot ALSO no longer silent-defaults to `"default"`.
  # Operators must pass `--instance-class <class>` on bare-name CLI
  # invocations for the three per-tenant schemes (`session`, `template`,
  # `resource`). Missing class on a bare name = `ArgumentError` with a
  # message that names the missing flag.
  #
  # Fully-typed instances (e.g. `--session team-alpha/generic/foo` or
  # `--session generic/foo`) skip the class fill and the explicit-class
  # check — the operator supplied the class inline.
  defp promote_to_3seg("session", instance, workspace, template_class),
    do: fill_caller_workspace_strict("session", workspace, instance, template_class)

  defp promote_to_3seg("template", instance, workspace, template_class),
    do: fill_caller_workspace_strict("template", workspace, instance, template_class)

  defp promote_to_3seg("resource", instance, workspace, template_class),
    do: fill_caller_workspace_strict("resource", workspace, instance, template_class)

  defp promote_to_3seg(_scheme, instance, _workspace, _template_class), do: instance

  # SPEC #366: bare-name needs `--instance-class <class>`; missing =
  # raise. Two-segment (`<class>/<name>`) and three-segment forms
  # already carry the class inline and are accepted as-is.
  defp fill_caller_workspace_strict(scheme, workspace, instance, template_class) do
    case Ezagent.URI.path_segments(instance) do
      [bare] ->
        class = require_template_class!(scheme, bare, template_class)
        "#{workspace}/#{class}/#{bare}"

      [type, bare] ->
        "#{workspace}/#{type}/#{bare}"

      [_type, _ws, _name | _rest] ->
        instance

      _ ->
        instance
    end
  end

  defp require_template_class!(_scheme, _bare, class)
       when is_binary(class) and class != "",
       do: class

  defp require_template_class!(scheme, bare, _missing) do
    raise ArgumentError,
          "missing required `--instance-class <class>` for `#{scheme}://` bare-name " <>
            "promotion. Got bare instance #{inspect(bare)}; promotion to the 3-segment " <>
            "`#{scheme}://<workspace>/<class>/<name>` URI requires an explicit class. " <>
            "Add `--instance-class <class>` to your CLI invocation, or pass the " <>
            "fully-qualified instance (e.g. `--#{scheme} <class>/<name>`). Per SPEC " <>
            "#366 / `feedback_let_it_crash_no_workarounds` — there is no silent " <>
            "`\"default\"` class fallback."
  end

  defp derive_caller(options) do
    # Phase 6 PR 7: per-process override set by `EzagentCli.Exec.exec/2`
    # when a valid CLI bearer token is presented. This takes precedence
    # over the legacy `--as` flag — token auth IS the caller identity.
    #
    # Codex CLI/GUI audit 2026-05-24 HIGH-1 / `feedback_let_it_crash_no_workarounds`:
    # the previous code silently fell back to `admin_uri + admin_caps`
    # when no token AND no --as flag was presented. Anyone with the
    # runtime cookie file then ran every mix task as admin. Closed:
    # we now REFUSE to run without an explicit identity. PR #123
    # closed the same hole on `/api/v1`; CLI was the leftover.
    case Process.get(:ezagent_cli_caller_override) do
      {%URI{} = uri, %MapSet{} = caps} ->
        {uri, caps}

      _ ->
        case Map.get(options, :as) do
          nil ->
            # No token + no --as = no identity. REFUSE rather than
            # silently elevate. Caller must either:
            # (a) set token-only EZAGENT_USER_TOKEN (the
            #     normal auth path used by `mix ezagent`), OR
            # (b) opt into dev-only impersonation via
            #     EZAGENT_CLI_ALLOW_AS=1 mix ezagent --as <uri> ...
            {:error, :no_identity}

          as_str ->
            case System.get_env("EZAGENT_CLI_ALLOW_AS") do
              "1" -> derive_other_user(as_str)
              _ -> {:error, :as_not_allowed}
            end
        end
    end
  end

  defp derive_other_user(as_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue preserving the `:bad_as_uri` error contract.
    try do
      uri = Ezagent.URI.new!(as_str)
      caps = lookup_identity_caps(uri)
      {uri, caps}
    rescue
      ArgumentError ->
        {:error, {:bad_as_uri, as_str}}
    end
  end

  defp lookup_identity_caps(uri) do
    # S4 I5 boundary #3: route the development-only `--as` slice load through
    # the same persistent, verified authority loader used by `Cap.issue/3`.
    # This keeps inline self-authority caps untouched while every cap copied
    # from an identity slice into dispatch ctx crosses `Cap.verify/1`.
    Ezagent.Identity.read_held_caps(uri)
  end

  # Restored to local dispatch — the pivot (Allen 2026-05-17) moves the
  # CLI VM problem upstream: Mix.Tasks.Esr no longer runs Dispatch
  # locally; it POSTs argv to the server's /api/cli/exec which runs
  # EzagentCli.Exec.exec → eventually calls THIS function inside the
  # running phx BEAM. So this code stays local — it's just that it
  # now runs in the right BEAM.
  defp do_dispatch(inv, :call, deadline_ms) do
    case Invocation.dispatch(inv) do
      {:ok, result} ->
        {:ok, result}

      :ok ->
        receive do
          {:ezagent_reply, reply} -> {:ok, reply}
        after
          deadline_ms -> {:ok, :ok}
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_dispatch(inv, :cast, _deadline_ms) do
    case Invocation.dispatch(inv) do
      :ok -> {:ok, :ok}
      {:ok, _} -> {:ok, :ok}
      {:error, _} = err -> err
    end
  end
end

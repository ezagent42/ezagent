defmodule EzagentCli.Dispatch do
  @moduledoc """
  Build `%Ezagent.Invocation{}` from parsed Optimus result and dispatch.

  Constructs target URI from the `--<kind_type>` instance arg, threads
  caps from the caller's own Identity slice (resolved via `derive_caller`,
  which REFUSES without an explicit identity — no admin fallback), waits on
  the caller mailbox for `:call` mode.
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

        # Boolean schema args are presence FLAGS in the Optimus tree
        # (`TreeBuilder.action_subcommand/4`), so they arrive in
        # `parsed.flags`, not `parsed.options`. Fold them back into the
        # action args (Optimus defaults absent flags to `false`), minus
        # the CLI-reserved control flags `:cast` / `:json` which are not
        # action args.
        bool_args = Map.drop(flags, [:cast, :json])

        action_args =
          options
          |> Map.drop(MapSet.to_list(reserved))
          |> Map.merge(bool_args)

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
              }
            }

            do_dispatch(inv, mode, deadline_ms)

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Generic dispatch verb (Phase 3 ③ T7f) — `mix ezagent dispatch <uri>
  --action <behavior.action> [--args <json>]`.

  The single escape hatch for per-instance role-mounted Behaviors (kanban,
  github, …) that are NOT statically registered in `BehaviorRegistry`, so the
  auto-derived `run_action/4` tree never exposes them. Caller identity + caps
  are derived the SAME way as `run_action/4` (`derive_caller/1` reads the
  per-process override `EzagentCli.Exec.exec/2` sets from the VERIFIED bearer
  token), so the Invocation carries the caller's OWN caps and the in-dispatch
  CapBAC gate authorizes exactly that caller — no privilege change versus the
  typed verbs, no static kanban registration, no per-op facade boilerplate.

  `parsed` is the Optimus result for the `dispatch` subcommand:
  `%{args: %{target: uri_str}, options: %{action:, args:, ...}, flags: %{}}`.
  """
  @spec run_dispatch(map()) :: {:ok, term()} | {:error, term()}
  def run_dispatch(parsed) do
    options = Map.get(parsed, :options, %{})
    pos_args = Map.get(parsed, :args, %{})
    flags = Map.get(parsed, :flags, %{})

    with {:ok, target_str} <- fetch_required(pos_args, :target, :missing_target_uri),
         {:ok, action_str} <- fetch_required(options, :action, :missing_action),
         {:ok, action_args} <- parse_args_json(Map.get(options, :args)),
         {:ok, target_uri} <- build_dispatch_target(target_str, action_str),
         {%URI{} = caller_uri, caps} <- derive_caller(options) do
      mode = if Map.get(flags, :cast, false), do: :cast, else: :call
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
        }
      }

      do_dispatch(inv, mode, deadline_ms)
    else
      # `derive_caller/1` may return `{:error, :no_identity | :as_not_allowed |
      # {:bad_as_uri, _}}` (a 2-tuple that does NOT match `{%URI{}, caps}`) and
      # the arg/URI guards return their own `{:error, _}` — all surface verbatim
      # so the CLI exits with a clear message instead of silently elevating.
      {:error, _} = err -> err
    end
  end

  @doc """
  `mix ezagent session send` (Phase 3 ③ T7h) — post a chat message into a
  session through the SANCTIONED `session.send` dispatch.

  The auto-derived `session send` verb declared `--message` as a JSON `:map`
  and handed `Behavior.Session.handle_send/2` a plain map, which never matches
  its `%{message: %Message{}}` head → the `:cast` was silently dropped (no row
  in `messages`, no fan-out). This verb instead builds a REAL
  `%Ezagent.Message{}` with server-side @mention resolution via
  `Ezagent.Session.MessageComposer.build_message/3` — the EXACT path the World
  UI chat composer uses (`Ezagent.World.ConversationData` delegates to the same
  composer) — so `@pm` in the text routes to the mentioned agent.

  Authorization is unchanged: the caller + caps come from the per-process
  override `EzagentCli.Exec.exec/2` set from the VERIFIED bearer token (no
  admin fallback), and the `:cast` rides the normal in-dispatch CapBAC gate.
  `:send` is a `:cast`-only action; we mirror the World composer's
  `mode: :cast, reply: :ignore`.

  `parsed` is the Optimus result for `session send`:
  `%{options: %{session:, message:, ...}, flags: %{cast:, json:}}`.
  """
  @spec run_session_send(map()) :: {:ok, term()} | {:error, term()}
  def run_session_send(parsed) do
    options = Map.get(parsed, :options, %{})

    with {:ok, instance} <- fetch_required(options, :session, :missing_session_uri),
         {:ok, text} <- fetch_required(options, :message, :missing_message),
         {%URI{} = caller_uri, caps} <- derive_caller(options),
         {:ok, session_uri} <- resolve_session_uri(instance, caller_uri, options) do
      msg = Ezagent.Session.MessageComposer.build_message(caller_uri, text, session_uri)
      target = Ezagent.URI.with_action(session_uri, :session, :send)
      deadline_ms = Map.get(options, :deadline_ms) || @default_deadline_ms

      inv = %Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: caller_uri,
          caps: caps,
          reply: :ignore,
          deadline_ms: deadline_ms
        }
      }

      do_dispatch(inv, :cast, deadline_ms)
    else
      # `derive_caller/1` may return `{:error, :no_identity | :as_not_allowed |
      # {:bad_as_uri, _}}` and the arg/URI guards return their own `{:error,
      # _}` — all surface verbatim so the CLI exits with a clear message.
      {:error, _} = err -> err
    end
  end

  # Resolve the `--session` instance to a canonical session URI. A full URI is
  # used as-is; a bare name is promoted structurally from the caller's workspace
  # (reusing the same `--instance-class` rules as the typed verbs, SPEC
  # #324/#366 — no silent `"default"` fallback) and built through the sanctioned
  # `Ezagent.URI.session/3` typed builder (no raw scheme-literal interpolation —
  # uri_query.scan gate).
  defp resolve_session_uri(instance, %URI{} = caller_uri, options) when is_binary(instance) do
    try do
      case Ezagent.URI.new!(instance) do
        %URI{scheme: "session"} = uri -> {:ok, uri}
        _ -> {:error, {:not_a_session_uri, instance}}
      end
    rescue
      ArgumentError ->
        caller_workspace = workspace_name_from_caller(caller_uri)
        instance_class = Map.get(options, :instance_class)
        promoted = promote_to_3seg("session", instance, caller_workspace, instance_class)

        case Ezagent.URI.path_segments(promoted) do
          [ws, class, name] -> {:ok, Ezagent.URI.session(ws, class, name)}
          _ -> {:error, {:malformed_session_instance, instance}}
        end
    end
  end

  # Required positional arg / option presence check. Absent or empty = a clear
  # error tuple (rendered to a non-zero exit by `EzagentCli.Formatter`).
  defp fetch_required(map, key, err) do
    case Map.get(map, key) do
      val when is_binary(val) and val != "" -> {:ok, val}
      _ -> {:error, err}
    end
  end

  # Append the operator-supplied `behavior.action` as the canonical `?action=`
  # query on the (canonicalized) target URI — mirrors `build_target_uri/6`'s
  # full-URI branch, but takes the action string verbatim (the whole point of
  # the generic verb is the behavior is NOT statically known here, so we can't
  # derive the slice segment from a `behavior_module`).
  defp build_dispatch_target(target_str, action_str) do
    if String.contains?(action_str, ".") do
      try do
        base = Ezagent.URI.new!(target_str)
        {:ok, Ezagent.URI.new!(URI.to_string(base) <> "?action=" <> action_str)}
      rescue
        ArgumentError -> {:error, {:malformed_target_uri, target_str}}
      end
    else
      {:error, {:bad_action_format, action_str}}
    end
  end

  # `--args` is a JSON OBJECT of action args. Top-level keys are atomized via
  # `String.to_existing_atom/1` (NEVER `to_atom/1` — no atom-table exhaustion:
  # every action arg name is a compile-time atom declared in the Behavior's
  # `action/3` macro). Nested values keep string keys — Behaviors that take map
  # args (kanban `attach_artifact`/`set_metric`) normalize inner keys
  # themselves (atom/string tolerant). Scalar JSON types (string/int/bool) map
  # to the corresponding Elixir terms, so no per-arg coercion is needed for the
  # behaviors this serves (kanban/github args are string/int/map).
  defp parse_args_json(nil), do: {:ok, %{}}
  defp parse_args_json(""), do: {:ok, %{}}

  defp parse_args_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> atomize_top_keys(map)
      {:ok, _other} -> {:error, {:args_not_a_json_object, json}}
      {:error, _} -> {:error, {:malformed_args_json, json}}
    end
  end

  defp atomize_top_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      try do
        {:cont, {:ok, Map.put(acc, String.to_existing_atom(k), v)}}
      rescue
        ArgumentError -> {:halt, {:error, {:unknown_arg_key, k}}}
      end
    end)
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
            # (a) set EZAGENT_USER_TOKEN + EZAGENT_ENTITY_URI (the
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
    # Lifecycle migration (PR #485 — Identity → use Ezagent.Lifecycle):
    # the `:identity` slice is now the two-container shape
    # `%{state: %{caps}, transients}`. Read through the canonical
    # `Ezagent.Kind.get_slice/2` chokepoint, which normalizes to the
    # flat `:state` view (T3); a raw `:sys.get_state` match on
    # `%{state: %{identity: %{caps: _}}}` would silently miss the
    # nested `:state` and return empty caps for `--as <uri>`.
    case Ezagent.Kind.get_slice(uri, :identity) do
      {:ok, %{caps: caps}} when is_struct(caps, MapSet) -> caps
      {:ok, %{caps: caps}} when is_list(caps) -> MapSet.new(caps)
      _ -> MapSet.new()
    end
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

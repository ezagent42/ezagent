defmodule Ezagent.Behavior.NpAgent do
  @moduledoc """
  NpAgent Behavior — receives chat messages, evaluates numpy / sympy
  expressions in a per-agent Python subprocess via `Ezagent.Domain.Python`,
  and dispatches the result back into the originating session.

  Registered for `(Ezagent.Entity.NpAgent, :receive | :configure | :reset)`
  in `EzagentPluginNp.Application`. The chat router targets
  `entity://agent/<ws>/np_<name>?action=chat.receive`; the dispatcher
  pattern-matches behavior_module to land here.

  ## Slice (state_slice :np_agent)

  See `Ezagent.Entity.NpAgent` moduledoc for the schema. This Behavior:
  - reads `python_handle` for outbound JSON-RPC calls
  - records `last_input / last_result / last_error` for observability

  ## Per-receive flow

  1. Extract `text` from message body — that's the expression / latex.
  2. Decide method: `compute_latex` if the text looks like LaTeX
     (contains `\\` or `^` or `_`), else `compute`. Plain `numpy/sympy`
     expressions go to `compute`.
  3. `Ezagent.Domain.Python.call(handle, method, %{"expr" => text}, 10_000)`
  4. On `{:ok, %{"result" => r}}`, format `"= <r>"` and dispatch
     `chat.send` back into the originating session.
  5. On error, format the error human-readably and reply with that.

  The Python script does the safety validation (no raw `eval`); see
  `np_compute_server.py` moduledoc.

  ## Loop safety

  Mirrors the curl_agent pattern: ignore messages whose sender is the
  np-agent itself (defensive — Resolver also drops the sender from
  fan-out, but {:always} rules + mention-gated routing both rely on
  this self-check).

  ## Cap reuse

  Reply dispatch runs under `Ezagent.Entity.User.admin_caps/0` — same
  v1 trust model as curl_agent / echo. Granular per-agent caps are a
  Phase 9 concern.
  """

  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.{Invocation, Message}
  alias Ezagent.Domain.Python

  @default_timeout_ms 10_000

  @impl Ezagent.Behavior
  def actions, do: [:receive, :reset, :configure]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:receive,
       "receive a session message and forward to the Python compute subprocess (sympy/numpy)"},
      {:reset, "tear down + respawn the Python compute subprocess (clears state)"},
      {:configure, "set or update the np-agent's subprocess config (timeout, allowed funcs)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :np_agent

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{
      # The Python subprocess handle. By convention the Template Class
      # uses the agent URI itself — one Server per NpAgent Kind.
      python_handle: Map.get(args, :python_handle) || Map.get(args, :uri),
      timeout_ms: Map.get(args, :timeout_ms, @default_timeout_ms),
      last_input: nil,
      last_result: nil,
      last_error: nil
    }
  end

  @impl Ezagent.Behavior
  def invoke(:receive, slice, %{message: %Message{} = msg}, ctx) do
    # Loop prevention: ignore messages we sent ourselves.
    self_uri_str = URI.to_string(ctx.self_uri)
    sender_str = sender_string(msg.sender)

    if sender_str == self_uri_str do
      {:ok, slice}
    else
      do_receive(slice, msg, ctx)
    end
  end

  def invoke(:reset, slice, _args, _ctx) do
    new_slice = %{slice | last_input: nil, last_result: nil, last_error: nil}
    {:ok, new_slice, %{ok: true}}
  end

  def invoke(:configure, slice, args, _ctx) when is_map(args) do
    new_slice = %{
      slice
      | timeout_ms: Map.get(args, :timeout_ms, slice.timeout_ms)
    }

    {:ok, new_slice, %{ok: true}}
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      receive: %{
        description:
          "Evaluate the inbound text as a numpy/sympy expression and reply " <>
            "with the computed value",
        args: %{message: :map},
        returns: %{ok: :boolean, result: :string, error: :atom},
        modes: [:cast]
      },
      reset: %{
        description: "Clear the agent's last_input / last_result / last_error",
        args: %{},
        returns: %{ok: :boolean},
        modes: [:call]
      },
      configure: %{
        description: "Update the agent's per-call timeout (ms)",
        args: %{timeout_ms: :integer},
        returns: %{ok: :boolean},
        modes: [:call]
      }
    }
  end

  # --- internals ---------------------------------------------------------

  defp do_receive(slice, %Message{} = msg, ctx) do
    text = extract_text(msg.body)
    source_session_uri = ctx[:caller]

    case run_compute(slice, text) do
      {:ok, result_value} ->
        result_text = "= #{format_result(result_value)}"
        new_slice = %{slice | last_input: text, last_result: result_value, last_error: nil}

        send_reply_to_session(source_session_uri, ctx.self_uri, result_text, msg)
        {:ok, new_slice, %{ok: true, result: result_text}}

      {:error, reason} ->
        Logger.warning(
          "NpAgent #{URI.to_string(ctx.self_uri)} compute failed " <>
            "input=#{inspect(text)} reason=#{inspect(reason)}"
        )

        new_slice = %{slice | last_input: text, last_result: nil, last_error: reason}

        reply_text = "compute error: #{format_error(reason)}"
        send_reply_to_session(source_session_uri, ctx.self_uri, reply_text, msg)
        {:ok, new_slice, %{ok: false, error: error_kind(reason)}}
    end
  end

  defp run_compute(slice, text) when is_binary(text) and text != "" do
    handle = slice.python_handle
    method = pick_method(text)
    timeout = slice.timeout_ms || @default_timeout_ms

    case Python.call(handle, method, %{"expr" => text}, timeout) do
      {:ok, %{"result" => r}} ->
        {:ok, r}

      {:ok, other} ->
        {:error, {:bad_python_result, other}}

      {:error, %{"code" => code, "message" => message}} ->
        {:error, {:python_error, code, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_compute(_slice, _empty), do: {:error, :empty_input}

  # Heuristic: latex if it contains a backslash command, `^`, `_`, or
  # `\\frac` etc. Pure numpy expressions (`2 + 2`, `sin(0.5)`,
  # `np.array([1,2,3]).sum()`) go to `compute`.
  defp pick_method(text) do
    cond do
      String.contains?(text, "\\") -> "compute_latex"
      true -> "compute"
    end
  end

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  defp sender_string(%URI{} = u), do: URI.to_string(u)
  defp sender_string(s) when is_binary(s), do: s
  defp sender_string(_), do: ""

  defp format_result(r) when is_number(r), do: to_string(r)
  defp format_result(r) when is_binary(r), do: r

  defp format_result(r) when is_list(r) do
    Enum.map(r, &format_result/1) |> Enum.join(", ") |> then(&("[" <> &1 <> "]"))
  end

  defp format_result(r), do: inspect(r)

  defp format_error({:python_error, code, message}),
    do: "python error #{code}: #{message}"

  defp format_error({:bad_python_result, other}),
    do: "unexpected python result shape: #{inspect(other)}"

  defp format_error(:not_alive), do: "python subprocess not running"
  defp format_error(:rpc_timeout), do: "python compute timed out"
  defp format_error(:empty_input), do: "empty input"
  defp format_error(reason), do: inspect(reason)

  defp error_kind({:python_error, _, _}), do: :python_error
  defp error_kind({:bad_python_result, _}), do: :bad_python_result
  defp error_kind(:not_alive), do: :not_alive
  defp error_kind(:rpc_timeout), do: :rpc_timeout
  defp error_kind(:empty_input), do: :empty_input
  defp error_kind(_), do: :other

  # Re-use the curl_agent reply-dispatch pattern.
  defp send_reply_to_session(nil, _, _, _), do: :ok
  defp send_reply_to_session("", _, _, _), do: :ok

  defp send_reply_to_session(session_uri, agent_uri, text, in_msg) do
    case parse_session_uri(session_uri) do
      nil ->
        :ok

      %URI{} = session ->
        msg =
          Message.new(agent_uri, %{text: text, attachments: []}, ref_id: in_msg.id)

        target = URI.new!("#{URI.to_string(session)}?action=chat.send")

        Invocation.dispatch(%Invocation{
          target: target,
          mode: :cast,
          args: %{message: msg},
          ctx: %{
            caller: agent_uri,
            caps: Ezagent.Entity.User.admin_caps(),
            reply: :ignore
          }
        })

        :ok
    end
  end

  defp parse_session_uri(%URI{scheme: "session"} = u), do: u

  defp parse_session_uri(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: "session"} = u} -> u
      _ -> nil
    end
  end

  defp parse_session_uri(_), do: nil

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): admin-only
  # Behavior — no per-entity owner; only bootstrap admin grants
  # via §5.2 admin branch. Test/demo Behaviors + system control
  # surfaces fall here pending dedicated SPEC for any specific
  # owner model they need (e.g. FeishuOutbound: future PR could
  # delegate to session owner like Chat does, but the current
  # outbound path is admin-gated).
  @impl Ezagent.Behavior
  def data_owner(_), do: :no_owner

end

defmodule EzagentPluginHello.LLM.ClaudeCode do
  @moduledoc """
  A `claude_code` LLM backend for hello generation — runs the LOCAL Claude Code
  CLI in HEADLESS mode (`claude -p`) instead of the DeepSeek HTTP API. Claude is a
  far stronger designer, so the frame / theme / content come out much better.

  Headless (`-p`), NOT the interactive PTY: generation is one-shot (prompt in →
  JSON/HTML out), and `-p --output-format text` gives clean text to parse. The
  PTY/TUI path is for conversational agents (the cc plugin), not generation.

  The combined system+user prompt is passed via STDIN (a temp file) — large hello
  prompts overflow argv. Uses the local Claude Code auth (no API key). Selected at
  runtime by `HELLO_LLM_BACKEND=claude_code`.

  Returns the same `{:ok, %{content: binary()}}` shape as the DeepSeek client so
  `Generator.call_llm/2` swaps transparently.
  """
  require Logger

  @spec chat(String.t(), String.t()) :: {:ok, %{content: String.t()}} | {:error, term()}
  def chat(system, user) when is_binary(system) and is_binary(user) do
    case bin() do
      nil -> {:error, :claude_not_found}
      claude -> run(claude, system <> "\n\n=== REQUEST ===\n\n" <> user)
    end
  end

  def chat(_, _), do: {:error, :bad_args}

  defp run(claude, prompt) do
    dir = Path.join(System.tmp_dir!(), "hello_claude_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    pf = Path.join(dir, "prompt.txt")

    try do
      File.write!(pf, prompt)
      # `claude -p` reads the prompt from STDIN when no positional arg is given.
      cmd = "#{claude} -p --output-format text #{model_flag()} < '#{pf}'"

      case System.cmd("sh", ["-c", cmd], stderr_to_stdout: false) do
        {out, 0} when is_binary(out) and out != "" ->
          {:ok, %{content: out}}

        {out, 0} ->
          {:error, {:claude_empty, out}}

        {err, code} ->
          Logger.warning("hello.ClaudeCode: exit #{code}: #{String.slice(err, 0, 300)}")
          {:error, {:claude_exit, code}}
      end
    rescue
      e ->
        Logger.warning("hello.ClaudeCode: crashed: #{inspect(e)}")
        {:error, {:claude_crash, e}}
    after
      File.rm_rf(dir)
    end
  end

  defp bin do
    System.get_env("HELLO_CLAUDE_BIN") ||
      System.find_executable("claude") ||
      Enum.find(
        [Path.expand("~/.local/bin/claude"), "/usr/local/bin/claude"],
        &File.exists?/1
      )
  end

  # Optional `HELLO_LLM_MODEL` → `--model <m>`; absent uses Claude Code's default.
  defp model_flag do
    case System.get_env("HELLO_LLM_MODEL") do
      m when is_binary(m) and m != "" -> "--model #{m}"
      _ -> ""
    end
  end
end

defmodule EzagentPluginCr.CrLint do
  @moduledoc """
  CR lint rules (R01-R05). Each rule inspects the tenant sandbox and returns
  a severity-tagged tuple: `{:ok, message}`, `{:warning, message}`, or `{:error, message}`.

  R01: No broken symlinks in sandbox — severity: error
  R02: All required files present (CLAUDE.md, skills/, kb/) — severity: error
  R03: No empty skill directories — severity: warning
  R04: Slot template syntax valid (balanced {{ }}) — severity: warning
  R05: KB database integrity check — severity: error
  """

  alias EzagentPluginContent.Tenant.TenantRuntime

  @required_entries ["CLAUDE.md", "skills", "kb"]

  @typedoc "A single lint result item: an :ok, :warning, or :error tuple with a message."
  @type lint_item :: {:ok, String.t()} | {:warning, String.t()} | {:error, String.t()}

  @typedoc "Aggregated lint check result."
  @type check_result ::
          {:ok, %{warnings: [lint_item()], ok: [lint_item()]}}
          | {:error, %{errors: [lint_item()], warnings: [lint_item()], ok: [lint_item()]}}

  @doc """
  Run all lint checks against the tenant's sandbox.

  Returns:
    - `{:ok, %{warnings: [...], ok: [...]}}` — all error-severity rules pass
    - `{:error, %{errors: [...], warnings: [...], ok: [...]}}` — at least one error-severity rule failed

  Each element in the lists is a tuple: `{:error, message}`, `{:warning, message}`, or `{:ok, message}`.
  """
  @spec check(String.t()) :: check_result()
  def check(tid) do
    rules = [
      r01_broken_symlinks(tid),
      r02_required_files(tid),
      r03_empty_skill_dirs(tid),
      r04_slot_syntax(tid),
      r05_kb_integrity(tid)
    ]

    errors = Enum.filter(rules, &(elem(&1, 0) == :error))
    warnings = Enum.filter(rules, &(elem(&1, 0) == :warning))
    ok = Enum.filter(rules, &(elem(&1, 0) == :ok))

    if errors != [] do
      {:error, %{errors: errors, warnings: warnings, ok: ok}}
    else
      {:ok, %{warnings: warnings, ok: ok}}
    end
  end

  # R01: No broken symlinks in sandbox — severity: error
  defp r01_broken_symlinks(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)

    if File.exists?(sandbox) do
      broken =
        sandbox
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.reject(&(File.exists?(&1) and not is_broken_symlink?(&1)))

      case broken do
        [] -> {:ok, "R01: no broken symlinks"}
        paths -> {:error, "R01: broken symlinks found: #{Enum.join(paths, ", ")}"}
      end
    else
      {:ok, "R01: sandbox not found, skipped"}
    end
  end

  # R02: All required files present — severity: error
  defp r02_required_files(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)

    if File.exists?(sandbox) do
      missing =
        Enum.reject(@required_entries, fn entry ->
          File.exists?(Path.join(sandbox, entry))
        end)

      case missing do
        [] -> {:ok, "R02: all required entries present"}
        entries -> {:error, "R02: missing required entries: #{Enum.join(entries, ", ")}"}
      end
    else
      {:error, "R02: sandbox does not exist"}
    end
  end

  # R03: No empty skill directories — severity: warning
  defp r03_empty_skill_dirs(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)
    skills_dir = Path.join(sandbox, "skills")

    if File.exists?(skills_dir) do
      empty =
        skills_dir
        |> Path.join("*")
        |> Path.wildcard()
        |> Enum.filter(&(File.dir?(&1) and Enum.empty?(File.ls!(&1))))

      case empty do
        [] -> {:ok, "R03: no empty skill directories"}
        dirs -> {:warning, "R03: empty skill directories: #{Enum.join(dirs, ", ")}"}
      end
    else
      {:ok, "R03: skills dir not found, skipped"}
    end
  end

  # R04: Slot template syntax valid (balanced {{ }}) — severity: warning
  defp r04_slot_syntax(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)

    if File.exists?(sandbox) do
      issues =
        sandbox
        |> Path.join("**/*.{ex,exs,heex,md,yaml,yml}")
        |> Path.wildcard()
        |> Enum.flat_map(fn file ->
          content = File.read!(file)
          unbalanced = unbalanced_slots(content)
          if unbalanced == [], do: [], else: ["R04: #{file}: #{Enum.join(unbalanced, ", ")}"]
        end)

      case issues do
        [] -> {:ok, "R04: slot syntax valid"}
        reasons -> {:warning, Enum.join(reasons, "; ")}
      end
    else
      {:ok, "R04: sandbox not found, skipped"}
    end
  end

  # R05: KB database integrity check — severity: error
  defp r05_kb_integrity(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)
    kb_db = Path.join(sandbox, "kb/kb.db")

    if File.exists?(kb_db) do
      # MVP: just verify the file is non-empty and readable
      stat = File.stat!(kb_db)
      if stat.size > 0, do: {:ok, "R05: kb.db integrity OK"}, else: {:error, "R05: kb.db is empty"}
    else
      {:ok, "R05: kb.db not found, skipped"}
    end
  end

  # Helpers

  defp is_broken_symlink?(path) do
    File.lstat!(path).type == :symlink and not File.exists?(path)
  rescue
    _ -> false
  end

  defp unbalanced_slots(content) when is_binary(content) do
    # Count open {{ and close }} — must be balanced
    opens = count_occurrences(content, "{{")
    closes = count_occurrences(content, "}}")

    errors = []
    errors = if opens == closes, do: errors, else: ["unbalanced {{/}} (open=#{opens}, close=#{closes})" | errors]
    errors
  end

  defp count_occurrences(text, pattern) do
    text
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end

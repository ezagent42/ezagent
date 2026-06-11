defmodule EzagentPluginCr.CrLint do
  @moduledoc """
  CR lint rules (R01-R05). Each rule inspects the tenant sandbox and returns
  `:ok` or a list of error strings.

  R01: No broken symlinks in sandbox
  R02: All required files present (CLAUDE.md, skills/, kb/)
  R03: No empty skill directories
  R04: Slot template syntax valid (balanced {{ }})
  R05: KB database integrity check
  """

  alias EzagentPluginContent.Tenant.TenantRuntime

  @required_entries ["CLAUDE.md", "skills", "kb"]

  @doc """
  Run all lint checks against the tenant's sandbox.
  Returns `:ok` on success (all rules pass) or `{:error, reasons}` on failure.
  """
  @spec check(String.t()) :: :ok | {:error, [String.t()]}
  def check(tid) do
    rules = [&check_r01/1, &check_r02/1, &check_r03/1, &check_r04/1, &check_r05/1]

    errors =
      Enum.reduce(rules, [], fn rule, acc ->
        case rule.(tid) do
          :ok -> acc
          {:error, reasons} -> acc ++ reasons
        end
      end)

    case errors do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  # R01: No broken symlinks in sandbox
  defp check_r01(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)

    if File.exists?(sandbox) do
      broken =
        sandbox
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.reject(&(File.exists?(&1) and not is_broken_symlink?(&1)))

      case broken do
        [] -> :ok
        paths -> {:error, ["R01: broken symlinks found: #{Enum.join(paths, ", ")}"]}
      end
    else
      :ok
    end
  end

  # R02: All required files present
  defp check_r02(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)

    if File.exists?(sandbox) do
      missing =
        Enum.reject(@required_entries, fn entry ->
          File.exists?(Path.join(sandbox, entry))
        end)

      case missing do
        [] -> :ok
        entries -> {:error, ["R02: missing required entries: #{Enum.join(entries, ", ")}"]}
      end
    else
      {:error, ["R02: sandbox does not exist"]}
    end
  end

  # R03: No empty skill directories
  defp check_r03(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)
    skills_dir = Path.join(sandbox, "skills")

    if File.exists?(skills_dir) do
      empty =
        skills_dir
        |> Path.join("*")
        |> Path.wildcard()
        |> Enum.filter(&(File.dir?(&1) and Enum.empty?(File.ls!(&1))))

      case empty do
        [] -> :ok
        dirs -> {:error, ["R03: empty skill directories: #{Enum.join(dirs, ", ")}"]}
      end
    else
      :ok
    end
  end

  # R04: Slot template syntax valid (balanced {{ }})
  defp check_r04(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)

    if File.exists?(sandbox) do
      errors =
        sandbox
        |> Path.join("**/*.{ex,exs,heex,md,yaml,yml}")
        |> Path.wildcard()
        |> Enum.flat_map(fn file ->
          content = File.read!(file)
          unbalanced = unbalanced_slots(content)
          if unbalanced == [], do: [], else: ["R04: #{file}: #{Enum.join(unbalanced, ", ")}"]
        end)

      case errors do
        [] -> :ok
        reasons -> {:error, reasons}
      end
    else
      :ok
    end
  end

  # R05: KB database integrity check (placeholder)
  defp check_r05(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)
    kb_db = Path.join(sandbox, "kb/kb.db")

    if File.exists?(kb_db) do
      # MVP: just verify the file is non-empty and readable
      stat = File.stat!(kb_db)
      if stat.size > 0, do: :ok, else: {:error, ["R05: kb.db is empty"]}
    else
      :ok
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

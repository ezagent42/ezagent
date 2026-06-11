defmodule EzagentPluginCr.Lint do
  @moduledoc """
  Pre-publish lint gate for a tenant's sandbox content.

  Runs two rules before a publish is allowed:

  - R01 (warning): unresolved `{{slot}}` placeholders in the rendered soul
    (claude_md). These are advisory — publish succeeds with warnings.

  - R03 (fatal): every skill path referenced in claude_md matching
    `plugins/<tid>/skills/<rel>` must exist as a file under
    `sandbox_dir(tid)/skills/<rel>`. First missing path → `{:error,
    {:missing_skill, rel}}`.
  """

  alias EzagentPluginContent.{TenantContent, TenantPaths}

  @placeholder_re ~r/\{\{\s*[A-Za-z0-9_.]+\s*\}\}/
  # Stop at whitespace, closing paren, backtick, or opening angle-bracket.
  # The Skill Index uses (plugins/<tid>/skills/<rel>) — paren-terminated.
  # Soul prose may use backtick-quoted paths — backtick-terminated.
  # Angle-bracket stops prevent matching instructional <placeholder> text
  # (e.g. `plugins/cinnox/skills/customer/<name>/SKILL.md` in skeleton prose).
  @skill_ref_re ~r{plugins/[^/]+/skills/([^\s)`<]+)}

  @spec run(tid :: String.t()) :: {:ok, warnings :: [String.t()]} | {:error, term()}
  def run(tid) when is_binary(tid) do
    with {:ok, ctx} <- TenantContent.provision_context(tid, "slow", source: :sandbox) do
      claude_md = ctx.claude_md || ""
      warnings = collect_placeholder_warnings(claude_md)

      case check_skill_refs(claude_md, tid) do
        :ok -> {:ok, warnings}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # R01 — placeholder warnings
  # ---------------------------------------------------------------------------

  defp collect_placeholder_warnings(text) do
    @placeholder_re
    |> Regex.scan(text)
    |> Enum.flat_map(& &1)
    |> Enum.uniq()
    |> Enum.map(fn placeholder -> "unresolved slot: #{placeholder}" end)
  end

  # ---------------------------------------------------------------------------
  # R03 — skill existence check (fatal)
  # ---------------------------------------------------------------------------

  defp check_skill_refs(text, tid) do
    skills_base = Path.join(TenantPaths.sandbox_dir(tid), "skills")

    @skill_ref_re
    |> Regex.scan(text)
    |> Enum.map(fn [_full, captured] -> captured end)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn rel_path, :ok ->
      full_path = Path.join(skills_base, rel_path)

      if File.exists?(full_path) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing_skill, rel_path}}}
      end
    end)
  end
end

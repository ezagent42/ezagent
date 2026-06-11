defmodule EzagentPluginCr.Lint do
  @moduledoc """
  Pre-publish lint gate for a tenant's sandbox content.

  Runs two rules before a publish is allowed:

  - R01 (warning): unresolved `{{slot}}` placeholders in the rendered soul
    (claude_md). These are advisory — publish succeeds with warnings.

  - R03 (fatal/warning): skill paths referenced in claude_md matching
    `plugins/<x>/skills/<rel>`:
    - If `<x> == tid` (same-tenant ref): the file must exist under
      `sandbox_dir(tid)/skills/<rel>`. First missing path → `{:error,
      {:missing_skill, rel}}`.
    - If `<x> != tid` (cross-namespace ref, e.g. `plugins/platform/...`):
      skip validation and append a WARNING (`"unverified cross-namespace skill
      ref: plugins/<x>/skills/<rel>"`). We cannot validate refs into other
      namespaces at publish time.
  """

  alias EzagentPluginContent.{TenantContent, TenantPaths}

  @placeholder_re ~r/\{\{\s*[A-Za-z0-9_.]+\s*\}\}/
  # Stop at whitespace, closing paren, backtick, or opening angle-bracket.
  # The Skill Index uses (plugins/<tid>/skills/<rel>) — paren-terminated.
  # Soul prose may use backtick-quoted paths — backtick-terminated.
  # Angle-bracket stops prevent matching instructional <placeholder> text
  # (e.g. `plugins/cinnox/skills/customer/<name>/SKILL.md` in skeleton prose).
  # Capture group 1 = namespace (<x>), group 2 = relative path.
  @skill_ref_re ~r{plugins/([^/]+)/skills/([^\s)`<]+)}

  @spec run(tid :: String.t()) :: {:ok, warnings :: [String.t()]} | {:error, term()}
  def run(tid) when is_binary(tid) do
    with {:ok, ctx} <- TenantContent.provision_context(tid, "slow", source: :sandbox) do
      claude_md = ctx.claude_md || ""
      warnings = collect_placeholder_warnings(claude_md)

      case check_skill_refs(claude_md, tid) do
        {:ok, ref_warnings} -> {:ok, warnings ++ ref_warnings}
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
  # R03 — skill existence check (fatal for same-tenant; warning for cross-ns)
  # ---------------------------------------------------------------------------

  defp check_skill_refs(text, tid) do
    skills_base = Path.join(TenantPaths.sandbox_dir(tid), "skills")

    @skill_ref_re
    |> Regex.scan(text)
    |> Enum.map(fn [_full, ns, rel] -> {ns, rel} end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn {ns, rel_path}, {:ok, warnings} ->
      if ns == tid do
        # Same-tenant reference: the skill file must exist — fatal if missing.
        full_path = Path.join(skills_base, rel_path)

        if File.exists?(full_path) do
          {:cont, {:ok, warnings}}
        else
          {:halt, {:error, {:missing_skill, rel_path}}}
        end
      else
        # Cross-namespace reference (e.g. plugins/platform/skills/...): we
        # cannot validate across namespaces at publish time — skip with a
        # warning so the tenant author is informed.
        warn = "unverified cross-namespace skill ref: plugins/#{ns}/skills/#{rel_path}"
        {:cont, {:ok, [warn | warnings]}}
      end
    end)
    |> then(fn
      {:ok, warnings} -> {:ok, Enum.reverse(warnings)}
      err -> err
    end)
  end
end

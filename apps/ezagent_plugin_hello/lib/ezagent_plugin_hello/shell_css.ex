defmodule EzagentPluginHello.ShellCss do
  @moduledoc """
  Compile the per-session AI **shell**'s Tailwind CSS at generation time.

  The shell's utility classes are AI-authored and live in the DB, so Tailwind's
  build-time scan can never see them (that is why an un-compiled shell renders
  ~half-unstyled). Instead we run the standalone Tailwind binary over THIS shell's
  HTML — with the customer theme tokens declared as `@theme` — producing the
  minimal CSS for exactly its classes, ARBITRARY values (`w-[800px]`) included.
  The result is stored next to the shell and inlined on the customer page.

  Fast (~40ms) and self-contained (no daisyUI plugin / vendor-path coupling — the
  theme tokens are inlined). Returns "" on any failure so generation never breaks.
  """
  require Logger

  # The customer surface theme tokens (mirrors apps/ezagent_web/assets/css/
  # customer.css). Declared as @theme so Tailwind emits `bg-primary`, `text-base-
  # content`, `from-accent`, … from them without the daisyUI plugin.
  @theme """
  @theme {
    --color-base-100: oklch(99% 0 0);
    --color-base-200: oklch(96% 0.001 286.375);
    --color-base-300: oklch(92% 0.004 286.32);
    --color-base-content: oklch(21% 0.006 285.885);
    --color-primary: oklch(58% 0.233 277.117);
    --color-primary-content: oklch(96% 0.018 272.314);
    --color-secondary: oklch(55% 0.027 264.364);
    --color-secondary-content: oklch(98% 0.002 247.839);
    --color-accent: oklch(60% 0.25 292.717);
    --color-accent-content: oklch(96% 0.016 293.756);
    --color-neutral: oklch(44% 0.017 285.786);
    --color-neutral-content: oklch(98% 0 0);
    --color-info: oklch(62% 0.214 259.815);
    --color-info-content: oklch(97% 0.014 254.604);
    --color-success: oklch(70% 0.14 182.503);
    --color-success-content: oklch(98% 0.014 180.72);
    --color-warning: oklch(66% 0.179 58.318);
    --color-warning-content: oklch(98% 0.022 95.277);
    --color-error: oklch(58% 0.253 17.585);
    --color-error-content: oklch(96% 0.015 12.422);
    --radius-selector: 0.5rem;
    --radius-field: 0.375rem;
    --radius-box: 0.75rem;
  }
  """

  @doc "Compile the minimal Tailwind CSS for `html`'s classes. Returns CSS, or \"\" on failure."
  @spec compile(term()) :: binary()
  def compile(html) when is_binary(html) and html != "" do
    case bin_path() do
      {:ok, bin} -> run(bin, html)
      :error -> ""
    end
  end

  def compile(_), do: ""

  defp run(bin, html) do
    dir = Path.join(System.tmp_dir!(), "hello_shellcss_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      html_path = Path.join(dir, "shell.html")
      in_path = Path.join(dir, "in.css")
      out_path = Path.join(dir, "out.css")
      File.write!(html_path, html)

      input =
        "@import \"tailwindcss\" source(none);\n@source \"" <>
          html_path <> "\";\n" <> @theme

      File.write!(in_path, input)

      case System.cmd(bin, ["--input", in_path, "--output", out_path, "--minify"],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          File.read!(out_path)

        {err, code} ->
          Logger.warning("hello.ShellCss: tailwind exited #{code}: #{String.slice(err, 0, 300)}")
          ""
      end
    rescue
      e ->
        Logger.warning("hello.ShellCss: compile crashed: #{inspect(e)}")
        ""
    after
      File.rm_rf(dir)
    end
  end

  # The standalone Tailwind v4 binary (the same one `mix tailwind` runs).
  defp bin_path do
    cond do
      Code.ensure_loaded?(Tailwind) and function_exported?(Tailwind, :bin_path, 0) ->
        # `apply/3` so the compiler doesn't warn on the dev-only `tailwind` dep.
        path = apply(Tailwind, :bin_path, [])
        if is_binary(path) and File.exists?(path), do: {:ok, path}, else: wildcard_bin()

      true ->
        wildcard_bin()
    end
  end

  defp wildcard_bin do
    Path.join([File.cwd!(), "_build", "tailwind-*"])
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, ".app"))
    |> case do
      [p | _] -> {:ok, p}
      _ -> :error
    end
  end
end

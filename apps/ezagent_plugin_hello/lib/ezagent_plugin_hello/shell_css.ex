defmodule EzagentPluginHello.ShellCss do
  @moduledoc """
  Compile the per-session AI **shell**'s Tailwind CSS at generation time.

  The shell's utility classes are AI-authored and live in the DB, so Tailwind's
  build-time scan can never see them (that is why an un-compiled shell renders
  ~half-unstyled). Instead we run the standalone Tailwind binary over THIS shell's
  HTML — with the customer theme tokens declared as `@theme` — producing the
  minimal CSS for exactly its classes, ARBITRARY values (`w-[800px]`) included.
  The result is stored next to the shell and inlined on the customer page.

  Fast (~40ms) and self-contained (no UI-plugin / vendor-path coupling — the
  theme tokens are inlined). Returns "" on any failure so generation never breaks.
  """
  require Logger

  # The customer surface theme tokens (mirrors apps/ezagent_web/assets/css/
  # viewer.css). Declared as @theme so Tailwind emits `bg-primary`,
  # `text-foreground`, `from-accent`, … without a UI plugin.
  @theme """
  @theme inline {
    --radius-sm: calc(var(--radius) - 4px);
    --radius-md: calc(var(--radius) - 2px);
    --radius-lg: var(--radius);
    --radius-xl: calc(var(--radius) + 4px);
    --color-background: var(--background);
    --color-foreground: var(--foreground);
    --color-card: var(--card);
    --color-card-foreground: var(--card-foreground);
    --color-popover: var(--popover);
    --color-popover-foreground: var(--popover-foreground);
    --color-primary: var(--primary);
    --color-primary-foreground: var(--primary-foreground);
    --color-secondary: var(--secondary);
    --color-secondary-foreground: var(--secondary-foreground);
    --color-muted: var(--muted);
    --color-muted-foreground: var(--muted-foreground);
    --color-accent: var(--accent);
    --color-accent-foreground: var(--accent-foreground);
    --color-destructive: var(--destructive);
    --color-destructive-foreground: var(--destructive-foreground);
    --color-border: var(--border);
    --color-input: var(--input);
    --color-ring: var(--ring);
  }

  :root {
    --ez-red: #D81830;
    --ez-blueink: #0048A8;
    --ez-yellow: #FFD400;
    --ez-jade: #0FA06E;
    --ez-cobalt: #0B5CFF;
    --ez-bg: #E8E8EB;
    --radius: 0.625rem;
    --radius-pill: 999px;
    --shadow-card: 0 1px 2px rgba(24, 24, 27, 0.06),
      0 8px 24px rgba(24, 24, 27, 0.08);
    --shadow-soft: 0 8px 24px rgba(24, 24, 27, 0.10);
    --background: var(--ez-bg);
    --foreground: oklch(21% 0.006 285.885);
    --card: oklch(100% 0 0);
    --card-foreground: oklch(21% 0.006 285.885);
    --popover: oklch(100% 0 0);
    --popover-foreground: oklch(21% 0.006 285.885);
    --primary: var(--ez-cobalt);
    --primary-foreground: oklch(100% 0 0);
    --secondary: oklch(96% 0.001 286.375);
    --secondary-foreground: oklch(21% 0.006 285.885);
    --muted: oklch(96% 0.001 286.375);
    --muted-foreground: oklch(55% 0.027 264.364);
    --accent: var(--ez-yellow);
    --accent-foreground: oklch(21% 0.006 285.885);
    --neutral: var(--ez-blueink);
    --neutral-foreground: oklch(98% 0 0);
    --destructive: var(--ez-red);
    --destructive-foreground: oklch(96% 0.015 12.422);
    --border: oklch(92% 0.004 286.32);
    --input: oklch(92% 0.004 286.32);
    --ring: var(--ez-cobalt);
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

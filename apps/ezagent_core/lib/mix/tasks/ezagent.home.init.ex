defmodule Mix.Tasks.Ezagent.Home.Init do
  @shortdoc "Create the EZAGENT_HOME profile skeleton (credentials/db/snapshots/logs/plugins)"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (bootstrap).**
  > Intentionally NOT a dispatched op. Creates the filesystem
  > skeleton the runtime BEAM needs to even start. Stays as
  > `mix ezagent.*`; do NOT migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Bootstrap row) + Finding 2 carve-out.

  Phase 5 PR 1: bootstrap `$EZAGENT_HOME/$EZAGENT_PROFILE/` per `docs/phase-specs/phase5/EZAGENT_HOME.md`.

  Idempotent — safe to re-run; only creates missing pieces.

      mix ezagent.home.init
      EZAGENT_HOME=/tmp/esr-test mix ezagent.home.init

  Refuses to write inside a git working tree unless `--inside-repo` is
  passed (operator wouldn't normally want runtime state polluting their
  repo).
  """
  use Mix.Task

  alias Ezagent.Home

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: [inside_repo: :boolean])

    refuse_if_inside_repo!(Home.profile_dir(), opts[:inside_repo])

    File.mkdir_p!(Home.profile_dir())
    set_perms(Home.profile_dir(), 0o700)

    Enum.each(Home.skeleton_dirs(), fn dir ->
      path = Home.path(dir)
      File.mkdir_p!(path)
      if dir == :credentials, do: set_perms(path, 0o700)
    end)

    ensure_credential_template(:feishu, feishu_template())
    ensure_credential_template(:"cc-channels", cc_channels_template())
    ensure_credentials_readme()

    # Deploy-seed SPEC §4: idempotently install shipped socialware packages into
    # the deployment dir (`socialware/`). Pure FS copy — no Repo/dispatch, so it
    # is safe in this Category-A bootstrap; the governed publish happens later at
    # boot via `Ezagent.Socialware.ManifestSeed.scan_all/1` (per-package isolating).
    Ezagent.Home.SocialwareSeed.seed!()
    Ezagent.Home.SkillSeed.seed!(index?: false)

    print_summary()
  end

  defp ensure_credential_template(name, body) do
    file = Path.join(Home.path(:credentials), "#{name}.yaml")

    unless File.exists?(file) do
      File.write!(file, body)
      set_perms(file, 0o600)
    end
  end

  defp feishu_template do
    """
    # Feishu adapter credentials — REQUIRED for ezagent_plugin_feishu.
    # Get these from Feishu's developer console (https://open.feishu.cn).
    # File mode is 600 — never commit, never share.
    app_id: cli_REPLACE_ME
    app_secret: REPLACE_ME
    encrypt_key: REPLACE_ME    # optional; required only if webhook encryption is enabled
    verification_token: REPLACE_ME    # required for webhook signature verification
    """
  end

  defp cc_channels_template do
    """
    # CC channel per-instance connect tokens — managed by Phase 5 PR 5.
    # mix ezagent.cc_channel.register adds entries; do not edit by hand.
    # File mode is 600 — tokens grant CC instance authority to connect.
    instances: {}
    """
  end

  defp ensure_credentials_readme do
    file = Path.join(Home.path(:credentials), "README.md")

    unless File.exists?(file) do
      File.write!(file, """
      # EZAGENT_HOME credentials

      Each YAML in this directory is a secret. Never commit, never share.
      Permissions are enforced 600 by the init task.

      ## Inventory

      - `feishu.yaml` — Feishu adapter app_id/app_secret/encrypt_key
      - `cc-channels.yaml` — CC channel per-instance connect tokens

      Add new credentials via plugin-provided mix tasks; manual editing is
      supported but template files document the required shape.
      """)
    end
  end

  defp refuse_if_inside_repo!(_path, true), do: :ok

  defp refuse_if_inside_repo!(path, _) do
    case System.cmd(
           "git",
           ["-C", path |> Path.dirname() |> ensure_dir(), "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        if path_inside_repo?(path) do
          Mix.raise("""
          Refusing to init EZAGENT_HOME inside a git repository: #{path}
          Runtime state would pollute the working tree. Either:
            • set EZAGENT_HOME=~/.ezagent (the default)
            • pass --inside-repo to override (NOT recommended)
          """)
        end

      _ ->
        :ok
    end
  end

  defp ensure_dir(p), do: if(File.dir?(p), do: p, else: System.tmp_dir!())

  defp path_inside_repo?(path) do
    case System.cmd("git", ["-C", File.cwd!(), "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {repo_root, 0} ->
        root = String.trim(repo_root)
        String.starts_with?(Path.expand(path), root)

      _ ->
        false
    end
  end

  defp set_perms(path, mode) do
    case :os.type() do
      {:unix, _} -> File.chmod!(path, mode)
      _ -> :ok
    end
  end

  defp print_summary do
    Mix.shell().info("EZAGENT_HOME = #{Ezagent.Home.profile_dir()}")
    Mix.shell().info("")

    Enum.each(
      [
        {"credentials/feishu.yaml", "REQUIRED before ezagent_plugin_feishu can start"},
        {"credentials/cc-channels.yaml", "managed by mix ezagent.cc_channel.register"},
        {"db/",
         "Phoenix Repo target (dev). One-time: mix ezagent.home.adopt_db moves repo-root ezagent_core_dev.db here"},
        {"snapshots/", "Phase 4 Kind state snapshots"},
        {"logs/", "server logs"},
        {"plugins/", "per-plugin non-secret tunables"},
        {"skills/", "deployment skill seed runtime origin"}
      ],
      fn {rel, note} ->
        full = Path.join(Home.profile_dir(), rel)
        marker = if File.exists?(full), do: "✓", else: "✗"
        Mix.shell().info("  [#{marker}] #{rel}  — #{note}")
      end
    )

    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Fill in credentials/feishu.yaml")
    Mix.shell().info("  2. Restart `mix phx.server` to pick up the new home")
  end
end

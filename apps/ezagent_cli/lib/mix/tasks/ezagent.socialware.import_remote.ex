defmodule Mix.Tasks.Ezagent.Socialware.ImportRemote do
  @shortdoc "Import a socialware manifest into the RUNNING node via distributed RPC (dev lane)"
  @moduledoc """
  D5 正路 RPC 导入(2026-07-18 拍板):dev 不开 boot-scan
  (`config.exs` 的 `socialware_manifest_boot_scan` 保持 prod-only,红线不动),
  改 manifest 后用本 task 把 YAML **字节** 推进**正在运行**的节点,在节点内走
  `Ezagent.Socialware.ManifestSeed.import_package/2` —— 与 boot-scan 同一条
  parse → resolve → conformance → governed `publish_or_upgrade` 治理链,零绕过,
  幂等语义一致(`:published` / `:upgraded` / `:exists`)。同目录 `recipes.yaml`
  (若存在)按 boot 路同样先行 seed。

  ## 用法

      mix ezagent.socialware.import_remote path/to/manifest.yaml \\
        [--node ezagent_runtime@127.0.0.1] \\
        [--cookie-file ~/.ezagent/default/runtime/cookie] \\
        [--dry-run]

  * `--node` — 运行节点名(默认 `EZAGENT_RUNTIME_NODE` env,再默认
    `ezagent_runtime@127.0.0.1`)。
  * `--cookie-file` — 分布式 Erlang cookie 文件(默认
    `~/.ezagent/default/runtime/cookie`;`EZAGENT_COOKIE` env 存在时优先,
    与 `Ezagent.Runtime.ensure_cookie!/0` 同序)。
  * `--dry-run` — 只在本地读取并解析 manifest / recipes,打印将导入的内容,
    不连节点、不发布。

  ## 为什么是 RPC 而不是本地跑 import

  mix task 进程没有运行节点的 Repo / registry / 插件上下文;在本地起一整套
  再 import 会与运行中的 server 抢同一份 `_build`/DB(历史 `.iex.exs` 手工
  workaround 的痛点)。本 task 刻意**最小化**:不 `app.start`、不读 app config,
  只读两个本地文件 + 一次 `:erpc.call`,所有治理逻辑都在运行节点内执行
  (与 `mix ezagent` CLI shell 同姿势,单机假设,Allen 2026-05-17)。

  失败一律 loud(`Mix.raise`):conformance / resolve 失败原样带出远端 reason。
  """

  use Mix.Task

  @default_node "ezagent_runtime@127.0.0.1"
  @default_cookie_file "~/.ezagent/default/runtime/cookie"
  @rpc_timeout 60_000

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [node: :string, cookie_file: :string, dry_run: :boolean]
      )

    if invalid != [] do
      Mix.raise("unknown options: #{inspect(invalid)}\n\n#{usage()}")
    end

    manifest_path =
      case args do
        [path] -> Path.expand(path)
        _ -> Mix.raise("expected exactly one <manifest.yaml> argument\n\n#{usage()}")
      end

    manifest_yaml = read_manifest!(manifest_path)
    recipes = read_sibling_recipes!(manifest_path)

    if opts[:dry_run] do
      dry_run(manifest_path, manifest_yaml, recipes)
    else
      node = connect!(opts)
      import_remote(node, manifest_yaml, recipes)
    end
  end

  # ── local file reads (the ONLY filesystem the task touches) ──────────────

  defp read_manifest!(path) do
    case File.read(path) do
      {:ok, yaml} ->
        yaml

      {:error, reason} ->
        Mix.raise("cannot read manifest #{path}: #{inspect(reason)}")
    end
  end

  # Sibling recipes.yaml (same dir as manifest.yaml) — optional, mirrors
  # ManifestSeed.seed_sibling_recipes/1's discovery rule.
  defp read_sibling_recipes!(manifest_path) do
    rp = Path.join(Path.dirname(manifest_path), "recipes.yaml")

    if File.exists?(rp) do
      case File.read(rp) do
        {:ok, yaml} -> {rp, yaml}
        {:error, reason} -> Mix.raise("cannot read #{rp}: #{inspect(reason)}")
      end
    else
      nil
    end
  end

  # ── dry-run: local parse only, no node connection ────────────────────────

  defp dry_run(manifest_path, manifest_yaml, recipes) do
    name = parse_manifest_name!(manifest_path, manifest_yaml)
    Mix.shell().info("[dry-run] manifest #{manifest_path} parses OK — name: #{name}")

    case recipes do
      {rp, yaml} ->
        recipe_names = parse_recipe_names!(rp, yaml)

        Mix.shell().info(
          "[dry-run] sibling #{rp} parses OK — recipes: #{Enum.join(recipe_names, ", ")}"
        )

      nil ->
        Mix.shell().info("[dry-run] no sibling recipes.yaml")
    end

    Mix.shell().info("[dry-run] would import via node RPC — nothing published")
  end

  defp parse_manifest_name!(path, yaml) do
    case Ezagent.Socialware.ManifestYaml.parse(yaml) do
      {:ok, %{"name" => name}} when is_binary(name) and name != "" ->
        name

      {:ok, attrs} ->
        Mix.raise("manifest #{path} has no usable `name`: #{inspect(Map.get(attrs, "name"))}")

      {:error, reason} ->
        Mix.raise("manifest #{path} does not parse: #{inspect(reason)}")
    end
  end

  defp parse_recipe_names!(path, yaml) do
    case Ezagent.Socialware.ManifestYaml.parse(yaml) do
      {:ok, %{"recipes" => list}} when is_list(list) ->
        Enum.map(list, fn
          %{"name" => name} when is_binary(name) and name != "" ->
            name

          other ->
            Mix.raise(
              "#{path} has an invalid recipe entry (needs a string `name`): #{inspect(other)}"
            )
        end)

      {:ok, other} ->
        Mix.raise("#{path} must have a top-level `recipes:` list, got: #{inspect(other)}")

      {:error, reason} ->
        Mix.raise("#{path} does not parse: #{inspect(reason)}")
    end
  end

  # ── distributed connection ───────────────────────────────────────────────

  defp connect!(opts) do
    cookie = resolve_cookie!(opts)

    node =
      String.to_atom(opts[:node] || System.get_env("EZAGENT_RUNTIME_NODE") || @default_node)

    local = :"ezagent_import_#{System.system_time(:nanosecond)}@127.0.0.1"

    case :net_kernel.start([local, :longnames]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "cannot start distributed Erlang (is epmd up? does the server run " <>
            "with distribution enabled?): #{inspect(reason)}"
        )
    end

    Node.set_cookie(cookie)

    if Node.connect(node) == true do
      node
    else
      Mix.raise(
        "cannot connect to #{node} — is the server running (mix phx.server), " <>
          "and does --cookie-file / EZAGENT_COOKIE match its cookie?"
      )
    end
  end

  # Same precedence as Ezagent.Runtime.ensure_cookie!/0: EZAGENT_COOKIE env
  # first (docker compose parity), then the cookie file. Missing file is a
  # loud error — this task never generates cookies.
  defp resolve_cookie!(opts) do
    case System.get_env("EZAGENT_COOKIE") do
      s when is_binary(s) and s != "" ->
        String.to_atom(String.trim(s))

      _ ->
        path = Path.expand(opts[:cookie_file] || @default_cookie_file)

        case File.read(path) do
          {:ok, content} ->
            String.to_atom(String.trim(content))

          {:error, reason} ->
            Mix.raise(
              "cannot read cookie file #{path} (#{inspect(reason)}) — " <>
                "pass --cookie-file or set EZAGENT_COOKIE"
            )
        end
    end
  end

  # ── the single RPC into the running node ─────────────────────────────────

  defp import_remote(node, manifest_yaml, recipes) do
    recipes_yaml =
      case recipes do
        {rp, yaml} ->
          Mix.shell().info("seeding sibling recipes from #{rp} on #{node} ...")
          yaml

        nil ->
          nil
      end

    result =
      try do
        :erpc.call(
          node,
          Ezagent.Socialware.ManifestSeed,
          :import_package,
          [manifest_yaml, recipes_yaml],
          @rpc_timeout
        )
      rescue
        e ->
          Mix.raise("remote import raised on #{node}: #{Exception.message(e)}")
      catch
        kind, reason ->
          Mix.raise("remote import failed on #{node}: #{inspect({kind, reason})}")
      end

    case result do
      {:ok, %{name: name, result: outcome}} ->
        Mix.shell().info("socialware #{name} → #{outcome} (on #{node})")

      {:error, {name, reason}} ->
        Mix.raise("import failed for #{name || "manifest"}: #{inspect(reason)}")
    end
  end

  defp usage do
    """
    usage: mix ezagent.socialware.import_remote <manifest.yaml> \\
             [--node ezagent_runtime@127.0.0.1] \\
             [--cookie-file ~/.ezagent/default/runtime/cookie] \\
             [--dry-run]
    """
  end
end

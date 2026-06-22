defmodule Mix.Tasks.Ezagent.Demo.SeedHello do
  @shortdoc "Seed a public_view hello app with a rendered seed page"
  @moduledoc """
  > **Demo seeder (CLI/GUI parity — Category A).** Like
  > `ezagent.demo.seed_cc_agent`, this is a demo-fixtures helper, NOT a normal
  > operator op; it stays `mix ezagent.demo.*`. The operator "new hello app" flow
  > is Phase 2. Every step here goes through the sanctioned authority
  > (`App.ensure_app` + `TurnDriver`, admin-genesis caps) — no raw node access.

  Instantiate a `public_view` hello app and land a **seed page** on its Surface,
  so an anonymous visitor can immediately see a builder-rendered `@json-render`
  page at `/socialware/chat`. No LLM is called (the seed page is fixed); this is
  the Phase-0 live-demo / agent-browser DoD fixture.

  ## Usage

      mix ezagent.demo.seed_hello            # ws="demo",  name="main"
      mix ezagent.demo.seed_hello acme home  # ws="acme",  name="home"

  ## What it does

  1. Ensures the workspace exists (idempotent).
  2. `App.ensure_app/2` — a `public_view` SessionTemplate, a live socialware
     Session bound to it, and a joined `HelloBuilder` member.
  3. `TurnDriver.drive/3` — opens → composes (`%{kind: :page, tree: Spec.seed()}`)
     → settles, so the seed page is born via `Surface.put_version` and approved.
  4. Prints the anonymous customer URL to open.

  Re-running is safe (`ensure_app` is idempotent; a new turn re-approves the
  seed page).
  """

  use Mix.Task

  alias Ezagent.Workspace
  alias EzagentPluginHello.{App, Spec, TurnDriver}

  @impl Mix.Task
  def run(args) do
    {ws, name} = parse(args)

    Mix.Task.run("app.start")

    _ = ensure_workspace(ws)

    case App.ensure_app(ws, name) do
      {:ok, session_uri, builder_uri} ->
        case TurnDriver.drive(session_uri, Spec.seed(), "Seed page — the hello builder is live.") do
          {:ok, turn_id} ->
            report(session_uri, builder_uri, turn_id)

          {:error, reason} ->
            Mix.shell().error("seed_hello: TurnDriver.drive failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("seed_hello: App.ensure_app failed: #{inspect(reason)}")
    end
  end

  defp parse([ws, name | _]), do: {ws, name}
  defp parse([ws]), do: {ws, "main"}
  defp parse(_), do: {"demo", "main"}

  defp ensure_workspace(ws) do
    case Workspace.create(ws, %{}) do
      {:ok, uri} -> {:ok, uri}
      {:error, {:already_started, _}} -> :ok
      # Already-existing workspace: not an error for an idempotent seed.
      {:error, _} -> :ok
    end
  end

  defp report(session_uri, builder_uri, turn_id) do
    path = "/socialware/chat?session_uri=#{URI.to_string(session_uri)}"

    Mix.shell().info("""

    hello app seeded (turn #{turn_id}):
      session : #{URI.to_string(session_uri)}
      builder : #{URI.to_string(builder_uri)}

    Open as an anonymous visitor (public_view — no login, an anon identity is
    minted automatically):
      #{path}
    """)
  end
end

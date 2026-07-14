if System.get_env("CAP_SIGNING_INVESTIGATION") == "1" do
  umbrella_lib = Path.expand("../../../_build/#{Mix.env()}/lib", __DIR__)

  if File.dir?(umbrella_lib) do
    for sibling <- File.ls!(umbrella_lib) do
      ebin = Path.join([umbrella_lib, sibling, "ebin"])
      if File.dir?(ebin), do: Code.prepend_path(ebin)
    end
  end

  # The real-data investigation runs with `mix test --no-start` so none of the
  # user/agent/session boot lanes can rewrite the restored fixture before the
  # test owns a sandbox transaction. Start only core (Repo + registries).
  {:ok, _started} = Application.ensure_all_started(:ezagent_core)
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)

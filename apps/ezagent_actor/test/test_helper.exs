ExUnit.start()

# V5 pid-closure use-side ENUMERATION (report-only) — ingress census hook.
# Gated on EZAGENT_INGRESS_CENSUS=1 so default suite runs are byte-identical
# (no collector process, no handler, no dump file). The dump feeds
# docs/notes/v5-use-side-ingress-census.md; it NEVER gates CI.
if System.get_env("EZAGENT_INGRESS_CENSUS") == "1" do
  _ = Ezagent.Kind.IngressCensus.Collector.attach()

  ExUnit.after_suite(fn _result ->
    path = Path.expand("../../../_build/census/ezagent_actor_ingress_census.txt", __DIR__)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      inspect(Ezagent.Kind.IngressCensus.Collector.observed(), pretty: true, limit: :infinity)
    )

    :ok
  end)
end

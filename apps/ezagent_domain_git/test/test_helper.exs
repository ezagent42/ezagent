ExUnit.start()

cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)

Application.put_env(
  :ezagent_core,
  Ezagent.Cap,
  Keyword.put(
    cap_config,
    :authority_loader,
    Ezagent.DomainGit.TestSupport.GitCapAuthorityLoader
  )
)

ExUnit.after_suite(fn _result ->
  Application.put_env(:ezagent_core, Ezagent.Cap, cap_config)
end)

defmodule Ezagent.Socialware.CommsSubstrateEliminationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.{Adapter, AdapterRegistry}
  alias Ezagent.Socialware.{ChatFeedAdapter, ExternalFeedAdapter}

  @repo_root Path.expand("../../../../..", __DIR__)
  @web_socialware_dir Path.join(
                        @repo_root,
                        "apps/ezagent_web/lib/ezagent_web/socialware"
                      )

  test "only the generic feed channel module remains" do
    refute File.exists?(Path.join(@web_socialware_dir, "chat_feed_channel.ex"))
    refute File.exists?(Path.join(@web_socialware_dir, "external_feed_channel.ex"))

    feed_channel_modules =
      @web_socialware_dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        Regex.scan(~r/defmodule\s+EzagentWeb\.Socialware\.(\w*FeedChannel)\b/, source)
        |> Enum.map(fn [_match, module] -> {module, Path.basename(path)} end)
      end)

    assert feed_channel_modules == [{"SessionFeedChannel", "session_feed_channel.ex"}]
  end

  test "legacy sockets now route through the generic channel" do
    assert socket_source("chat_feed_socket.ex") =~
             ~s(channel "socialware:chat_feed:*", EzagentWeb.Socialware.SessionFeedChannel)

    assert socket_source("external_feed_socket.ex") =~
             ~s(channel "socialware:external:*", EzagentWeb.Socialware.SessionFeedChannel)
  end

  test "chat and external pull adapters are registered with their delivery disciplines intact" do
    assert {:ok, ChatFeedAdapter} = AdapterRegistry.lookup("chat_feed")
    assert {:ok, ExternalFeedAdapter} = AdapterRegistry.lookup("external_feed")

    assert Adapter.kind_of(ChatFeedAdapter) == :pull
    assert Adapter.kind_of(ExternalFeedAdapter) == :pull

    assert Adapter.delivery_discipline_of(ChatFeedAdapter) == :snapshot_refresh
    assert Adapter.participation_profile_of(ChatFeedAdapter) == :read_only

    assert Adapter.delivery_discipline_of(ExternalFeedAdapter) == :cursor_replay
    assert Adapter.participation_profile_of(ExternalFeedAdapter) == :participatory
  end

  test "external_mirror dependency DAG stays below session and socialware" do
    mix_source =
      @repo_root
      |> Path.join("apps/ezagent_domain_external_mirror/mix.exs")
      |> File.read!()
      |> strip_line_comments()

    refute mix_source =~ "{:ezagent_domain_session, in_umbrella: true}"
    refute mix_source =~ "{:ezagent_domain_socialware, in_umbrella: true}"
  end

  defp socket_source(file) do
    @web_socialware_dir
    |> Path.join(file)
    |> File.read!()
  end

  defp strip_line_comments(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end
end

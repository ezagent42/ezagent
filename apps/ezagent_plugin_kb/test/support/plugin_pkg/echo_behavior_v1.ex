defmodule EzagentPluginPkgTest.EchoBehavior do
  @moduledoc false
  # Test fixture behavior for the plugin-package E2E gate. A real plugin
  # author would write this in their plugin app; here it lives under
  # test/support so the E2E can copy its compiled beam into a built
  # package dir and hot-load it through the real install path.

  use Ezagent.Lifecycle, state_slice: :echo_pkg

  @version "v1"

  action(:echo_pkg,
    args: %{text: :string},
    returns: %{echo: :string, version: :string},
    caps: [:echo_pkg],
    modes: [:call],
    description: "echo the supplied text back (plugin-package E2E fixture, v1)"
  )

  def required_caps do
    %{echo_pkg: Ezagent.Capability.cap(:agent, __MODULE__, :echo_pkg)}
  end

  def data_owner(_), do: :no_owner

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  def handle_echo_pkg(args, _ctx) do
    {:ok, %{echo: Map.get(args, :text) || Map.get(args, "text"), version: @version}, []}
  end
end

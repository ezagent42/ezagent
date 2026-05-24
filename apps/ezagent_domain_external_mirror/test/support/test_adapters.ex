defmodule Ezagent.ExternalMirror.TestSupport.MockAdapter do
  @moduledoc """
  In-test mock Adapter for the AdapterRegistry / BindingRegistry /
  facade tests (PR-EM-1). Implements only the PR-EM-1 callbacks.
  """
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "mock_em"

  @impl true
  def display_name, do: "Mock EM Adapter"

  @impl true
  def description, do: "Test-only adapter for PR-EM-1 registry tests."

  @impl true
  def binding_module, do: Ezagent.ExternalMirror.TestSupport.MockBinding
end

defmodule Ezagent.ExternalMirror.TestSupport.MockBinding do
  @moduledoc """
  In-test mock Binding paired with `MockAdapter`. Implements only
  the PR-EM-1 callbacks.
  """
  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: Ezagent.ExternalMirror.TestSupport.MockAdapter
end

defmodule Ezagent.ExternalMirror.TestSupport.OtherAdapter do
  @moduledoc "A second adapter for collision tests — same id as MockAdapter."
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "mock_em"

  @impl true
  def display_name, do: "Other EM Adapter (same id)"

  @impl true
  def description, do: "Second adapter claiming the same id — should be rejected."

  @impl true
  def binding_module, do: Ezagent.ExternalMirror.TestSupport.OtherBinding
end

defmodule Ezagent.ExternalMirror.TestSupport.OtherBinding do
  @moduledoc "Paired binding for OtherAdapter."
  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: Ezagent.ExternalMirror.TestSupport.OtherAdapter
end

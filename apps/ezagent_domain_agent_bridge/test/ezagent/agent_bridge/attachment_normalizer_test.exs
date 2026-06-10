defmodule Ezagent.AgentBridge.AttachmentNormalizerTest do
  @moduledoc """
  Cleanup-2 dedup: the cc + codex bridge adapters shared a byte-identical
  attachment-normalization trio (`normalize_attachments` /
  `normalize_attachment_keys` / `normalize_attachment_value`). It now lives
  once here; these tests pin the behavior both adapters rely on.
  """
  use ExUnit.Case, async: true

  alias Ezagent.AgentBridge.AttachmentNormalizer, as: N

  describe "normalize_attachments/1" do
    test "converts string keys + string type value to atoms" do
      input = [%{"type" => "image", "local_path" => "/tmp/a.png", "name" => "a.png"}]

      assert [%{type: :image, local_path: "/tmp/a.png", name: "a.png"}] =
               N.normalize_attachments(input)
    end

    test "maps every known type value to its atom" do
      for {str, atom} <- [
            {"image", :image},
            {"file", :file},
            {"audio", :audio},
            {"video", :video},
            {"media", :media}
          ] do
        assert [%{type: ^atom}] = N.normalize_attachments([%{"type" => str}])
      end
    end

    test "leaves an unknown type value as-is" do
      assert [%{type: "exotic"}] = N.normalize_attachments([%{"type" => "exotic"}])
    end

    test "passes through unknown string keys unchanged" do
      assert [%{"extra" => "v", :type => :file}] =
               N.normalize_attachments([%{"type" => "file", "extra" => "v"}])
    end

    test "leaves non-binary keys untouched" do
      assert [%{type: :image}] = N.normalize_attachments([%{:type => :image}])
    end

    test "passes through non-map list entries unchanged" do
      assert ["raw", 42] = N.normalize_attachments(["raw", 42])
    end

    test "returns an empty list for an empty list" do
      assert [] == N.normalize_attachments([])
    end
  end

  describe "normalize_attachment_keys/1" do
    test "normalizes a single map" do
      assert %{type: :file, name: "x"} =
               N.normalize_attachment_keys(%{"type" => "file", "name" => "x"})
    end
  end
end

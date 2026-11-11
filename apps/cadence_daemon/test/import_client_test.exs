defmodule Cadence.Daemon.ImportClientTest do
  use ExUnit.Case, async: true

  alias Cadence.Daemon.ImportClient

  test "attrs/2 omits unset flags so the daemon defaults apply" do
    attrs = ImportClient.attrs("/tmp/example", refs: [], limit: nil, name: nil)

    assert attrs == %{"work_dir" => "/tmp/example"}
    refute Map.has_key?(attrs, "allow_shallow")
    refute Map.has_key?(attrs, "all_refs")
    refute Map.has_key?(attrs, "refs")
  end

  test "attrs/2 sends explicit booleans and repeated refs" do
    attrs =
      ImportClient.attrs("/tmp/example",
        refs: ["main", "v1"],
        all_refs: true,
        allow_shallow: false,
        limit: 50,
        project: "project-id"
      )

    assert attrs["refs"] == ["main", "v1"]
    assert attrs["all_refs"] == true
    assert attrs["allow_shallow"] == false
    assert attrs["limit"] == 50
    assert attrs["project_id"] == "project-id"
  end
end

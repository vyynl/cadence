defmodule Cadence.ServerWeb.Components.RepoTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Cadence.ServerWeb.Components.Repo

  test "renders a submodule entry as text, not a file link" do
    entries = [
      %{name: "lib", type: :tree, path: "lib"},
      %{name: "vendor", type: :commit, path: "vendor"}
    ]

    html =
      render_component(&Repo.tree/1, %{
        entries: entries,
        hidden_count: 0,
        truncated?: false,
        project_slug: "demo",
        node_id: "n1",
        current_path: ""
      })

    assert html =~ "submodule"
    assert html =~ ~s(href="/p/demo/n/n1/tree/lib")
    refute html =~ ~s(href="/p/demo/n/n1/blob/vendor")
    refute html =~ ~s(href="/p/demo/n/n1/tree/vendor")
  end
end

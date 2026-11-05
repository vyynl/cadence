defmodule Cadence.ServerWeb.MeldsPageTest do
  @moduledoc """
  End-to-end smoke test for 4b: a pipeline-produced meld proposal is
  anonymously readable through the 4a-2 proposal page.
  """

  use Cadence.ServerWeb.ConnCase, async: false

  import Cadence.ServerFixtures

  alias Cadence.Server.{Melds, TestMeldLLM}

  setup do
    previous = Application.get_env(:cadence_server, :meld_llm)
    Application.put_env(:cadence_server, :meld_llm, TestMeldLLM)
    TestMeldLLM.setup()

    on_exit(fn ->
      if previous do
        Application.put_env(:cadence_server, :meld_llm, previous)
      else
        Application.delete_env(:cadence_server, :meld_llm)
      end

      TestMeldLLM.reset()
    end)

    :ok
  end

  test "anonymous visitors see the meld diff for a pipeline-created proposal", %{conn: conn} do
    owner = Ecto.UUID.generate()
    project = project(owner, %{name: "Meld Page"})
    membership(project, owner, :owner)

    parent_a = node_with_snapshot(project, %{"edit.txt" => "one"})
    parent_b = node_with_snapshot(project, %{"edit.txt" => "two"})

    TestMeldLLM.script([
      {:ok, "MELD_BEGIN\nFILE MODIFY edit.txt\n<<<\nmerged\n>>>\nMELD_END\n"}
    ])

    assert {:ok, proposal} =
             Melds.propose(%{id: owner}, project.id, [parent_a.id, parent_b.id])

    html = conn |> get("/proposals/#{proposal.token}") |> html_response(200)

    assert html =~ "Meld proposal"
    assert html =~ "edit.txt"
    assert html =~ "modified"
  end
end

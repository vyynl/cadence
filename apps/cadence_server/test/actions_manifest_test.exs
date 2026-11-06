defmodule Cadence.Server.Actions.ManifestTest do
  use ExUnit.Case, async: true

  alias Cadence.Server.Actions.Manifest
  alias Cadence.Server.Actions.Manifest.Action

  defp manifest(actions, extra \\ %{}) do
    Jason.encode!(Map.merge(%{"actions" => actions}, extra))
  end

  defp action(attrs \\ %{}) do
    Map.merge(
      %{"name" => "run_analysis", "command" => "python actions/run.py"},
      attrs
    )
  end

  describe "parse/2" do
    test "parses the spec example" do
      json =
        manifest([
          %{
            "name" => "download_data",
            "command" => "python actions/download_data.py",
            "description" => "Fetch latest dataset",
            "expose" => true
          },
          %{
            "name" => "run_analysis",
            "command" => "jupyter nbconvert --execute analysis.ipynb",
            "description" => "Run the analysis notebook",
            "expose" => true
          }
        ])

      assert {:ok, %Manifest{actions: [download, analysis]}} = Manifest.parse(json)

      assert %Action{name: "download_data", expose: true, description: "Fetch latest dataset"} =
               download

      assert %Action{name: "run_analysis", command: "jupyter nbconvert --execute analysis.ipynb"} =
               analysis
    end

    test "defaults optional fields and ignores unknown keys" do
      json =
        manifest([
          Map.merge(action(), %{
            "expose" => true,
            "env" => %{"DEBUG" => "1"},
            "timeout" => 30
          })
        ])

      assert {:ok, %Manifest{actions: [action]}} = Manifest.parse(json)
      assert action.description == nil
      assert action.expose == true
    end

    test "an empty action list is valid" do
      assert {:ok, %Manifest{actions: []}} = Manifest.parse(manifest([]))
    end

    test "defaults expose to false and ignores unknown top-level keys" do
      json = manifest([action()], %{"version" => 2, "generated_by" => "cadence"})

      assert {:ok, %Manifest{actions: [%Action{expose: false}]}} = Manifest.parse(json)
    end

    test "rejects control and bidi characters in descriptions" do
      for bad <- ["ok\u0001", "spoof\u{202E}text"] do
        assert Manifest.parse(manifest([Map.put(action(), "description", bad)])) ==
                 {:error, :invalid_description}
      end
    end

    test "rejects whitespace-only commands" do
      assert Manifest.parse(manifest([Map.put(action(), "command", "   ")])) ==
               {:error, :invalid_command}
    end

    test "accepts the exact boundary lengths" do
      name = String.duplicate("a", 64)
      command = String.duplicate("a", 512)
      description = String.duplicate("a", 200)

      json =
        manifest([
          %{"name" => name, "command" => command, "description" => description}
        ])

      assert {:ok, %Manifest{actions: [action]}} = Manifest.parse(json)
      assert action.name == name
      assert action.command == command
      assert action.description == description
    end

    test "invalid cap options fall back to the defaults" do
      json = manifest([action()])
      assert {:ok, _manifest} = Manifest.parse(json, max_bytes: "nope", max_actions: nil)
    end

    test "rejects malformed JSON" do
      assert Manifest.parse("{not json") == {:error, :invalid_json}
    end

    test "rejects a payload without an actions list" do
      assert Manifest.parse(Jason.encode!(%{"actions" => "nope"})) == {:error, :invalid_manifest}
      assert Manifest.parse(Jason.encode!(%{})) == {:error, :invalid_manifest}
      assert Manifest.parse("[]") == {:error, :invalid_manifest}
      assert Manifest.parse(nil) == {:error, :invalid_manifest}
    end

    test "rejects non-map action entries" do
      assert Manifest.parse(manifest(["nope"])) == {:error, :invalid_action}
      assert Manifest.parse(manifest([%{"command" => "echo hi"}])) == {:error, :invalid_name}
      assert Manifest.parse(manifest([%{"name" => "ok"}])) == {:error, :invalid_command}
    end

    test "enforces the byte cap before decoding" do
      json = manifest([action()])
      assert match?({:ok, _}, Manifest.parse(json, max_bytes: byte_size(json)))
      assert Manifest.parse(json, max_bytes: byte_size(json) - 1) == {:error, :too_large}
    end

    test "enforces the action-count cap" do
      json = manifest([Map.put(action(), "name", "one"), Map.put(action(), "name", "two")])
      assert {:ok, _manifest} = Manifest.parse(json, max_actions: 2)
      assert Manifest.parse(json, max_actions: 1) == {:error, :too_many_actions}
    end

    test "validates the action name grammar" do
      for bad <- ["Run", "-run", "run analysis", "", String.duplicate("a", 65)] do
        assert Manifest.parse(manifest([Map.put(action(), "name", bad)])) ==
                 {:error, :invalid_name}
      end
    end

    test "accepts the documented name characters" do
      for good <- ["a", "run_analysis", "download-data", "run2"] do
        assert {:ok, %Manifest{actions: [%Action{name: ^good}]}} =
                 Manifest.parse(manifest([Map.put(action(), "name", good)]))
      end
    end

    test "validates commands" do
      for bad <- ["", String.duplicate("a", 513), "echo \u0000", "echo\nrm -rf /"] do
        assert Manifest.parse(manifest([Map.put(action(), "command", bad)])) ==
                 {:error, :invalid_command}
      end

      assert {:ok, _manifest} =
               Manifest.parse(
                 manifest([Map.put(action(), "command", "sh -c 'echo a && echo b'")])
               )
    end

    test "validates descriptions and expose" do
      assert Manifest.parse(manifest([Map.put(action(), "description", 123)])) ==
               {:error, :invalid_description}

      assert Manifest.parse(
               manifest([Map.put(action(), "description", String.duplicate("a", 201))])
             ) ==
               {:error, :invalid_description}

      assert Manifest.parse(manifest([Map.put(action(), "expose", "yes")])) ==
               {:error, :invalid_expose}
    end

    test "rejects duplicate names" do
      json = manifest([action(), action()])
      assert Manifest.parse(json) == {:error, :duplicate_action}
    end
  end
end

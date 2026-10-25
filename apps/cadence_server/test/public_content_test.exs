defmodule Cadence.Server.PublicContentTest do
  use ExUnit.Case, async: true

  alias Cadence.Server.PublicContent

  describe "redact/1" do
    test "leaves ordinary commit messages unchanged" do
      assert PublicContent.redact("fix token parsing in the auth flow") ==
               {"fix token parsing in the auth flow", []}
    end

    test "redacts provider tokens and reports findings" do
      text = "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789"

      assert {redacted, findings} = PublicContent.redact(text)
      assert redacted =~ "[REDACTED]"
      refute redacted =~ "ghp_"
      assert :github_token in findings
    end

    test "redacts AWS access key IDs" do
      {redacted, findings} = PublicContent.redact("key AKIAIOSFODNN7EXAMPLE")

      assert redacted =~ "[REDACTED]"
      assert :aws_access_key in findings
    end

    test "redacts private key blocks" do
      text = """
      before
      -----BEGIN OPENSSH PRIVATE KEY-----
      c2VjcmV0
      -----END OPENSSH PRIVATE KEY-----
      after
      """

      {redacted, findings} = PublicContent.redact(text)

      assert redacted =~ "[REDACTED]"
      refute redacted =~ "c2VjcmV0"
      assert :private_key in findings
    end

    test "redacts generic assignments" do
      {redacted, findings} = PublicContent.redact(~s(password = "correct-horse-battery"))

      assert redacted =~ "[REDACTED]"
      assert :generic_assignment in findings
    end
  end

  describe "redact_message/1" do
    test "returns nil for nil" do
      assert PublicContent.redact_message(nil) == nil
    end

    test "returns the redacted string" do
      assert PublicContent.redact_message("token: ghp_abcdefghijklmnopqrstuvwxyz0123456789") ==
               "token: [REDACTED]"
    end
  end

  describe "sensitive?/1" do
    test "detects a secret" do
      assert PublicContent.sensitive?("sk-ant-abcdefghijklmnopqrstuvwxyz")
    end

    test "does not flag an ordinary message" do
      refute PublicContent.sensitive?("update README")
    end
  end

  describe "path filtering" do
    test "flags sensitive basenames" do
      for path <- [".env", ".env.local", "config/prod.pem", "id_rsa", "secrets.yml"] do
        assert PublicContent.sensitive_path?(path), "expected #{path} to be sensitive"
      end
    end

    test "allows example/template names but still flags the path" do
      assert PublicContent.sensitive_path?(".env.example")
      assert PublicContent.allowed_sensitive_path?(".env.example")
      assert PublicContent.allowed_sensitive_path?("config/credentials.example")
      refute PublicContent.allowed_sensitive_path?(".env.local")
    end

    test "filters entries and counts hidden files" do
      entries = [
        %{path: "README.md", name: "README.md", type: :blob},
        %{path: ".env", name: ".env", type: :blob},
        %{path: ".env.example", name: ".env.example", type: :blob},
        %{path: "src", name: "src", type: :tree}
      ]

      assert {visible, 1} = PublicContent.filter_entries(entries)
      assert Enum.map(visible, & &1.path) == ["README.md", ".env.example", "src"]
    end
  end

  describe "binary?/1" do
    test "detects NUL and invalid UTF-8" do
      assert PublicContent.binary?(<<0, 1, 2>>)
      assert PublicContent.binary?(<<0xFF, 0xFE>>)
      refute PublicContent.binary?("plain text")
    end
  end

  describe "quarantine?/1" do
    test "quarantines a sensitive path" do
      assert PublicContent.quarantine?([%{path: ".env", content: "SAFE=1"}])
    end

    test "quarantines a secret in ordinary text" do
      assert PublicContent.quarantine?([
               %{path: "README.md", content: "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789"}
             ])
    end

    test "does not quarantine clean or allowed-example files" do
      refute PublicContent.quarantine?([
               %{path: "README.md", content: "# Cadence"},
               %{path: ".env.example", content: "TOKEN=placeholder"}
             ])
    end
  end
end

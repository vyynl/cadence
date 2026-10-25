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
end

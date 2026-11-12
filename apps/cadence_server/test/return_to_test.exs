defmodule Cadence.ServerWeb.ReturnToTest do
  use ExUnit.Case, async: true

  alias Cadence.ServerWeb.ReturnTo

  test "accepts local absolute paths" do
    assert ReturnTo.safe("/p/cadence-demo?tab=tree") == "/p/cadence-demo?tab=tree"
    assert ReturnTo.safe("/") == "/"
  end

  test "rejects open redirects and control characters" do
    assert ReturnTo.safe("//evil.example") == "/"
    assert ReturnTo.safe("https://evil.example") == "/"
    assert ReturnTo.safe("\\\\evil.example") == "/"
    assert ReturnTo.safe("/\\evil") == "/"
    assert ReturnTo.safe("/p/x\nSet-Cookie: nope") == "/"
    assert ReturnTo.safe("") == "/"
    assert ReturnTo.safe(nil) == "/"
  end

  test "rejects auth pages to avoid loops" do
    assert ReturnTo.safe("/sign-in") == "/"
    assert ReturnTo.safe("/sign-in/totp") == "/"
    assert ReturnTo.safe("/auth/passkeys/sign-in") == "/"
  end

  test "rejects an over-long path" do
    assert ReturnTo.safe("/" <> String.duplicate("a", 3000)) == "/"
  end
end

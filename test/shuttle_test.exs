defmodule ShuttleTest do
  use ExUnit.Case

  test "version returns semantic version" do
    assert Shuttle.version() == "0.1.0"
  end
end

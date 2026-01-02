defmodule BurrowTest do
  use ExUnit.Case
  doctest Burrow

  test "greets the world" do
    assert Burrow.hello() == :world
  end
end

defmodule KeeperTest do
  use ExUnit.Case
  doctest Keeper

  test "greets the world" do
    assert Keeper.hello() == :world
  end
end

defmodule GrncShared.XForwardedForTest do

  use ExUnit.Case
  use Plug.Test

  alias GrncShared.Plugs.XForwardedFor, as: X
  test "overwrites remote_ip if x-forwarded-for is set" do

    ips = [
      {"192.168.2.3", {192, 168, 2, 3}},
      {"193.168.2.3", {193, 168, 2, 3}},
      {"194.168.2.3", {194, 168, 2, 3}},
    ]

    Enum.each(ips, fn {header, expected_remote_ip} ->
      conn = conn(:get, "/")
             |> Map.put(:remote_ip, {0, 0, 0, 1})
             |> put_req_header("x-forwarded-for", header)
             |> X.call([])

      assert conn.remote_ip == expected_remote_ip
    end)
  end

  test "does not overwrite remote_ip if x-forwarded-for is invalid" do

    ips = [
      {"foo", {0, 0, 0, 1}},
      {"", {0, 0, 0, 1}},
    ]

    Enum.each(ips, fn {header, expected_remote_ip} ->
      conn = conn(:get, "/")
             |> Map.put(:remote_ip, {0, 0, 0, 1})
             |> put_req_header("x-forwarded-for", header)
             |> X.call([])

      assert conn.remote_ip == expected_remote_ip
    end)
  end

  test "does not overwrite remote_ip if x-forwarded-for is not set" do

    conn = conn(:get, "/")
           |> Map.put(:remote_ip, {0, 0, 0, 1})
           |> X.call([])

    assert conn.remote_ip == {0, 0, 0, 1}
  end
end

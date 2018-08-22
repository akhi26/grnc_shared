defmodule GrncShared.Plugs.XForwardedFor do

  require Logger
  alias Plug.Conn
  @behaviour Plug

  @x_forwarded_for_header "x-forwarded-for"

  def init(opts), do: opts

  def call(conn, _opts) do
    case Conn.get_req_header(conn, @x_forwarded_for_header) do
      [x_forwarded_for | _] when is_binary(x_forwarded_for) ->
        case x_forwarded_for |> to_charlist |> :inet.parse_address() do
          {:ok, ip} ->
            %{conn | remote_ip: ip}
          _ ->
            conn
        end
      _ -> conn
    end
  end

end

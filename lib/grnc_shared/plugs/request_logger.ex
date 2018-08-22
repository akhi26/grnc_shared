defmodule GrncShared.Plugs.RequestLogger do
  # NOTE: make sure the logger doesn't truncate the output by adding the following
  # to the config/prod.exs `config :logger, truncate: :infinity`
  # NOTE: this logger uses the request_id, so it must be added after the Plug.RequestId
  # NOTE: the user can give us the x-request-id header to help us debug

  @moduledoc """
  A plug for logging all our request information in the format:

  [info] method=POST path=//api/v3/hotels/availability request_id=du7cgtb8h902tfi9dmorq9phtnngeii2 request_ip=127.0.0.1 api_key=9fc347d336d20b36c681262b493f04f2
  [info] method=POST path=//api/v3/hotels/availability request_id=du7cgtb8h902tfi9dmorq9phtnngeii2 request_ip=127.0.0.1 api_key=9fc347d336d20b36c681262b493f04f2 status=200 duration=1846ms timestamp=2016-11-21T09:15:28.477714Z ||request={...} ||response={...}

  To use it, just plug it into the desired module.

  plug GrncHub.RequestLogger, log: :debug, path_prefix: "/api/"

  ## Options

  * `:log` - The log level at which this plug should log its request info.
  Default is `:info`.
  * `message_meta` - This is a module which should implement a include_response?(request_path, log_type)
    and include_request?(request, log_type) methods which return a boolean

    defmodule AllMessageMeta do
      def include_request?(_, _), do: true
      def include_response?(_, _), do: true
    end

    end
  """

  require Logger
  alias Plug.Conn
  @behaviour Plug
  @spacer ?\s

  def init(opts) do
    %{
      level: Keyword.get(opts, :log, :info),
      message_meta: (Keyword.get(opts, :message_meta) || raise ArgumentError),
    }
  end


  def call(conn, %{level: level, message_meta: message_meta}) do
    start = System.monotonic_time()

    Logger.log level, fn ->
      [
        "I", @spacer,
        basic_info(conn),
        include(message_meta, :include_request?, conn, :in,
                fn -> ["||request=", request_body(conn), @spacer] end),
      ]
    end

    Conn.register_before_send(conn, fn conn ->
      Logger.log level, fn ->
        stop = System.monotonic_time()
        diff = System.convert_time_unit(stop - start, :native, :micro_seconds)
        [
          "O", @spacer,
          basic_info(conn),
          "status=", Integer.to_string(conn.status), @spacer,
          "duration=", formatted_diff(diff), @spacer,
          include(message_meta, :include_request?, conn, :out,
                  fn -> ["||request=", request_body(conn), @spacer] end),
          include_response(message_meta, :include_response, conn, :out,
                  fn(response) -> ["||response=", response, @spacer] end),
        ]
      end
      conn
    end)
  end

  defp include(message_meta, method, conn, log_type, payload) do
    if apply(message_meta, method, [conn, log_type]) do
      [payload.()]
    else
      []
    end
  end

  defp include_response(message_meta, method, conn, log_type, payload) do
    {include, response} = apply(message_meta, method, [conn, log_type])
    if include do
      [payload.(response)]
    else
      []
    end
  end

  defp basic_info(conn) do
    [
      "method=", conn.method, @spacer,
      "path=", conn.request_path, @spacer,
      "request_id=", Logger.metadata[:request_id], @spacer,
      "request_ip=", formatted_ip(conn.remote_ip), @spacer,
      "api_key=", header(conn, "api-key"), @spacer,
      "timestamp=", DateTime.to_iso8601(DateTime.utc_now), @spacer,
    ]
  end

  defp formatted_diff(diff) when diff > 1000, do: [diff |> div(1000) |> Integer.to_string, "ms"]
  defp formatted_diff(diff), do: [diff |> Integer.to_string, "µs"]

  defp formatted_ip(ip), do: ip |> Tuple.to_list |> Enum.join(".")
  defp header(conn, key) do
    conn |> Conn.get_req_header(key) |> List.first |> to_string
  end

  # NOTE: removing new lines from the input request doesn't change its meaning
  @newline ~r(\n|\r)
  @card_number_rx ~r/\d{13,}/
  @cvv_rx ~r/"card_cv2"[\s]*:[\s]*"[^"]+"/
  defp request_body(conn) do
    conn.private[:raw_body]
    |> to_string
    |> String.replace(@newline, "")
    |> String.replace(@card_number_rx, "[FILTERED]")
    |> String.replace(@cvv_rx, ~s("card_cv2" : "[FILTERED]"))
  end
end


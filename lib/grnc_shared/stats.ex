defmodule GrncShared.Stats do
  @behaviour GenServer
  use GenServer

  defmodule DataDogStore do
    def save(_request_id, stats)
    when is_list(stats) do
      Enum.map(stats,
               fn {event, event_stats}->
                 ExStatsD.timer(event_stats.time_ms,
                                to_string(event),
                                tags: DataDogStore.meta_to_tags(event_stats.meta))
               end)
    end

    def meta_to_tags(%{} = meta),
      do: Enum.map(meta, fn {k,v} -> "#{k}:#{v}" end)
  end

  # attrs
  @stats_tab :grnc_shared_stats_tab

  require Logger

  @doc """
  Used to record metrics for counters
  e.g.
        Stats.counter(:hotel_search)
        Stats.counter(:city_search)
        Stats.counter(:hotel_availability_request)
        Stats.counter(:hotel_booking_request)
        Stats.counter(:transfer_booking_request)

  """
  def counter(metric, meta \\ %{}, amount \\ 1, store \\ ExStatsD)
  when is_atom(metric) and is_integer(amount) and is_map(meta) do
    store.counter(amount, metric, tags: DataDogStore.meta_to_tags(meta))
  end

  @doc """
  Used to record gauges
  e.g.
        Stats.gauge(:open_ports, :erlang.ports |> length)

  """
  def gauge(metric, meta \\ %{}, amount \\ 1, store \\ ExStatsD)
  when is_atom(metric) and is_number(amount) and is_map(meta) do
    store.gauge(amount, metric, tags: DataDogStore.meta_to_tags(meta))
  end

  @doc """
  Used to record a histogram
  e.g.
        Stats.histogram(:response_hotel_count, 2000, %{search_id: "foobar", supplier: "gta"})

  """
  def histogram(metric, amount, meta \\ %{}, store \\ ExStatsD)
  when is_atom(metric) and is_number(amount) and is_map(meta) do
    store.histogram(amount, metric, tags: DataDogStore.meta_to_tags(meta))
  end

  @doc """
  Used to record sets
  e.g.
        Stats.set(:open_ports, :erlang.ports |> length)

  """
  def set(metric, meta \\ %{}, amount \\ 1, store \\ ExStatsD)
  when is_atom(metric) and is_number(amount) and is_map(meta) do
    store.gauge(amount, metric, tags: DataDogStore.meta_to_tags(meta))
    ExStatsD.set
  end

  # TODO: wrap this module in a try catch, so it never fails

  ## client api ####################
  def timer_start(request_id, event, meta \\ %{})
  when is_binary(request_id) and (is_atom(event) or is_tuple(event)) and is_map(meta) do
    result = if event_recorded?(request_id, event, :timer_start) do
      Logger.warn("OVERWRITING stats for #{request_id} and EVENT: #{inspect event}")
      :overwrote_old_value
    else
      :ok
    end
    :ets.insert(@stats_tab, {request_id, {:timer_start, event, DateTime.utc_now, meta}})
    result
  end

  def timer_end(request_id, event, meta \\ %{})
  when is_binary(request_id) and (is_atom(event) or is_tuple(event)) and is_map(meta) do
    result = if event_recorded?(request_id, event, :timer_end) do
      Logger.warn("OVERWRITING stats for #{request_id} and EVENT: #{inspect event}")
      :overwrote_old_value
    else
      :ok
    end
    :ets.insert(@stats_tab, {request_id, {:timer_end, event, DateTime.utc_now, meta}})
    result
  end
  defp event_recorded?(request_id, event, event_type) do
    :ets.match(@stats_tab, {request_id, {event_type, event, :_, :_}})
    |> Enum.any?
  end

  def time(request_id, event, timed_fun, meta \\ %{})
  when is_binary(request_id) and (is_atom(event) or is_tuple(event))
    and is_map(meta) and is_function(timed_fun, 0) do
    {time_micros, result} = :timer.tc(timed_fun)
    time_ms = time_micros / 1000
    :ets.insert(@stats_tab, {request_id, {:time, event, time_ms, meta}})
    result
  end

  def timer(request_id, event, time_ms, meta \\ %{})
  when is_binary(request_id) and (is_atom(event) or is_tuple(event))
    and is_map(meta) and is_number(time_ms) and time_ms >= 0 do
    :ets.insert(@stats_tab, {request_id, {:time, event, time_ms, meta}})
  end

  def report(request_id, store \\ DataDogStore)
  when is_binary(request_id) do
    stats =
      :ets.lookup(@stats_tab, request_id)
      |> Enum.map(fn {_, event} -> event end)
      |> Enum.group_by(&event_grouper/1)
      |> Enum.flat_map(fn {{_event_type, event}, timer_data} ->
        Enum.map(aggregate_event_data(timer_data), fn event_stats ->
          {normalize_event(event), event_stats}
        end)
      end)

    if stats != [] do
      store.save(request_id, stats)
      :ets.delete(@stats_tab, request_id)
      :ok
    else
      Logger.warn("STATS NOT FOUND FOR REQUEST_ID: #{request_id}")
      :not_found
    end
  rescue
    e ->
      Logger.error("ERROR_IN_STATS_REPORT: #{inspect e}")
      Logger.error("STACKTRACE: #{inspect System.stacktrace}")
      {:error, e}
  end

  defp event_grouper({:time, event, _event_dt, _event_meta}), do: {:time, event}
  defp event_grouper({event_type, event, _event_dt, _event_meta})
  when event_type == :timer_start or event_type == :timer_end do
    {:interval, event}
  end

  defp normalize_event({event, _event_id}), do: event
  defp normalize_event(event), do: event

  defmodule EventStats do
    defstruct event: nil, time_ms: 0, meta: %{}
  end

  defp aggregate_event_data(event_data = [{:time, _event, _time_ms, _meta} | _]) do
    Enum.map(event_data, fn {:time, event, time_ms, meta} ->
      %EventStats{event: event, time_ms: time_ms, meta: meta}
    end)
  end
  defp aggregate_event_data(event_data) do
    with {:start, {start_dt, start_meta}} <- {:start, extract_event_data(:timer_start, event_data)},
         {:end, {end_dt, end_meta}} <- {:end, extract_event_data(:timer_end, event_data)},
         time_ms = datetime_diff(end_dt, start_dt) do
          [%EventStats{time_ms: time_ms, meta: Map.merge(start_meta, end_meta)}]
    else
        err ->
           Logger.warn("ERROR_INCOMPLETE_EVENT_DATA err:#{inspect err} data:#{inspect event_data}")
           []
    end
  end

  defp extract_event_data(event_type, []) do
    Logger.warn("ERROR #{event_type} not found in stats")
    :grn_shared_stats_event_not_found
  end
  defp extract_event_data(event_type, [{event_type, _, start_dt, start_meta} | _]) do
    {start_dt, start_meta}
  end
  defp extract_event_data(event_type, [_ | rest]), do: extract_event_data(event_type, rest)
  defp datetime_diff(end_dt, start_dt) do
    DateTime.to_unix(end_dt, :milliseconds) - DateTime.to_unix(start_dt, :milliseconds)
  end

  ## server callbacks ##############
  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(state) do
    :ets.new(@stats_tab, [:named_table,
                          :bag, # to allow multiple events on a single request
                          {:write_concurrency, true},
                          {:read_concurrency, true},
                          :public])
    {:ok, state}
  end

end

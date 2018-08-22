defmodule GrncShared.StatsTest do
  use ExUnit.Case

  alias GrncShared.Stats

  defmodule StatsStore do
    def save(request_id, stats)
    when is_binary(request_id) and is_list(stats) do
      send self(), {:stats, request_id, stats}
    end

    def counter(amount, metric, [tags: tags]) do
      send self(), {:counter, metric, amount, tags}
    end

    def gauge(amount, metric, [tags: tags]) do
      send self(), {:gauge, metric, amount, tags}
    end

    def histogram(amount, metric, [tags: tags]) do
      send self(), {:histogram, metric, amount, tags}
    end
  end

  def recv(response_id) do
    receive do
      {:stats, ^response_id, stats} ->
        stats
    after 0 -> raise "Didn't receive expected message"
    end
  end

  def req_id do
    "rq_id_#{System.unique_integer([:positive, :monotonic])}"
  end

  describe "timer_start and timer_end" do

    test "capture the time in milliseconds" do
      req = req_id()
      Stats.timer_start(req, :resp)
      :timer.sleep(10)
      Stats.timer_end(req, :resp)
      assert Stats.report(req, StatsStore) == :ok

      stats = recv(req)[:resp]
      assert round(stats.time_ms) in 10..20
    end

    test "allows to optionally pass a unique identifier with event" do
      req = req_id()
      Stats.timer_start(req, {:resp, 1}, %{b: 1})
      Stats.timer_start(req, {:resp, 2}, %{b: 2})
      :timer.sleep(10)
      Stats.timer_end(req, {:resp, 2}, %{a: 3})
      Stats.timer_end(req, {:resp, 1}, %{a: 4})
      assert Stats.report(req, StatsStore) == :ok

      stats = recv(req)
      assert length(stats) == 2
      {:resp, stat1} = Enum.find(stats, fn {:resp, stat} -> match?(%{a: 3}, stat.meta) end)
      {:resp, stat2} = Enum.find(stats, fn {:resp, stat} -> match?(%{a: 4}, stat.meta) end)
      assert round(stat1.time_ms) in 10..20
      assert round(stat2.time_ms) in 10..20
      assert stat1.meta == %{a: 3, b: 2}
      assert stat2.meta == %{a: 4, b: 1}
    end

    test "captures meta passed in start" do
      req = req_id()
      Stats.timer_start(req, :resp, %{size: 100})
      Stats.timer_end(req, :resp)
      Stats.report(req, StatsStore)
      stats = recv(req)[:resp]
      assert stats.meta.size == 100
    end

    test "captures meta passed in end" do
      req = req_id()
      Stats.timer_start(req, :resp, %{size: 100})
      Stats.timer_end(req, :resp, %{bytes: 300})
      Stats.report(req, StatsStore)
      stats = recv(req)[:resp]
      assert stats.meta.bytes == 300
    end

    test "can track multiple event times based on request_id" do
      Stats.timer_start("a", :resp, %{size: 1})
      Stats.timer_start("b", :resp, %{size: 2})
      Stats.timer_end("b", :resp, %{bytes: 3})
      Stats.timer_start("c", :resp, %{size: 4})
      Stats.timer_end("a", :resp, %{bytes: 5})
      Stats.timer_end("c", :resp, %{bytes: 6})

      Stats.report("a", StatsStore)
      assert %{meta: %{bytes: 5, size: 1}} = recv("a")[:resp]
      Stats.report("b", StatsStore)
      assert %{meta: %{bytes: 3, size: 2}} = recv("b")[:resp]
      Stats.report("c", StatsStore)
      assert %{meta: %{bytes: 6, size: 4}} = recv("c")[:resp]
    end

    test "merges start and end meta" do
      req = req_id()
      Stats.timer_start(req, :resp, %{size: 100, st: 3})
      Stats.timer_end(req, :resp, %{bytes: 300, bt: 4})
      Stats.report(req, StatsStore)
      stats = recv(req)[:resp]
      assert %{meta: %{bt: 4, bytes: 300, size: 100, st: 3}} = stats
    end

    test "end meta overrides start meta" do
      req = req_id()
      Stats.timer_start(req, :resp, %{size: 100, st: 3})
      Stats.timer_end(req, :resp, %{bytes: 300, st: 4})
      Stats.report(req, StatsStore)
      stats = recv(req)[:resp]
      assert %{meta: %{bytes: 300, size: 100, st: 4}} = stats
    end

    test "deletes event data after report" do
      req = req_id()
      Stats.timer_start(req, :resp, %{size: 100})
      Stats.timer_end(req, :resp)

      Stats.report(req, StatsStore)
      stats = recv(req)[:resp]
      assert %{meta: %{size: 100}} = stats

      assert Stats.report(req, StatsStore) == :not_found
    end

    defmodule FaultyStore do
      def save(_request_id, _stats) do
        raise "ERROR IN STORE"
      end
    end

    test "should never throw an error" do
      req = req_id()
      Stats.timer_end(req, :resp)

      assert :not_found = Stats.report(req, FaultyStore)
    end

    test "warns if end not called on an event" do
      req = req_id()
      Stats.timer_end(req, :resp)

      assert :not_found = Stats.report(req, StatsStore)
    end

    test "warns if a start overwrites a previous start" do
      req = req_id()
      assert :ok == Stats.timer_start(req, :resp)
      assert :overwrote_old_value == Stats.timer_start(req, :resp)
    end

    test "warns if a end overwrites a previous end" do
      req = req_id()
      assert :ok == Stats.timer_start(req, :resp)
      assert :ok == Stats.timer_end(req, :resp)
      assert :overwrote_old_value == Stats.timer_end(req, :resp)
    end

    test "warns if report doesn't have any event details" do
      assert :not_found = Stats.report(req_id(), StatsStore)
    end

  end

  describe "timer with callback" do
    test "reports time" do
      req = req_id()
      Stats.time(req, :resp, fn -> :timer.sleep(10) end, %{size: 100})
      Stats.timer_start(req, :read, %{size: 200})
      :timer.sleep(5)
      Stats.timer_end(req, :read)

      Stats.report(req, StatsStore)
      stats = recv(req)

      resp_stats = stats[:resp]
      assert %{meta: %{size: 100}} = resp_stats
      assert round(resp_stats.time_ms) in 10..20

      read_stats = stats[:read]
      assert %{meta: %{size: 200}} = read_stats
      assert round(read_stats.time_ms) in 5..8
    end

    test "allows logging the same event multiple times" do
      req = req_id()
      Stats.time(req, :resp, fn -> :timer.sleep(10) end, %{size: 10})
      Stats.time(req, :resp, fn -> :timer.sleep(20) end, %{size: 20})
      Stats.timer_start(req, :resp, %{size: 30})
      :timer.sleep(5)
      Stats.timer_end(req, :resp)

      assert :ok == Stats.report(req, StatsStore)
      stats = recv(req)

      {:resp, s1} = Enum.find(stats, fn {:resp, stats} -> stats.meta.size == 10 end)
      {:resp, s2} = Enum.find(stats, fn {:resp, stats} -> stats.meta.size == 20 end)
      {:resp, s3} = Enum.find(stats, fn {:resp, stats} -> stats.meta.size == 30 end)

      assert round(s1.time_ms) in 10..12
      assert round(s2.time_ms) in 20..22
      assert round(s3.time_ms) in 5..7
    end

    test "returns callbacks value" do
      req = req_id()
      assert :r1 = Stats.time(req, :resp, fn ->
        :timer.sleep(10)
        :r1
      end, %{size: 100})
      assert :r2 = Stats.time(req, :resp, fn ->
        :timer.sleep(3)
        :r2
      end, %{size: 100})
    end

    test "error in callback should be propagated" do
      req = req_id()
      assert_raise RuntimeError, "Blah", fn ->
        Stats.time(req, :resp, fn ->
          :timer.sleep(10)
          raise "Blah"
        end)
      end
    end

  end

  describe "timer with time" do
    test "records time" do
      req = req_id()
      Stats.timer(req, :resp, 1, %{size: 1})
      Stats.timer(req, :resp, 2.2, %{size: 2})
      Stats.time(req, :resp, fn -> :timer.sleep(10) end, %{size: 3})
      Stats.timer_start(req, :resp, %{size: 4})
      :timer.sleep(5)
      Stats.timer_end(req, :resp)

      assert :ok == Stats.report(req, StatsStore)
      stats = recv(req)

      {:resp, s1} = Enum.find(stats, fn {:resp, stats} -> stats.meta.size == 1 end)
      {:resp, s2} = Enum.find(stats, fn {:resp, stats} -> stats.meta.size == 2 end)
      {:resp, s3} = Enum.find(stats, fn {:resp, stats} -> stats.meta.size == 3 end)
      {:resp, s4} = Enum.find(stats, fn {:resp, stats} -> stats.meta.size == 4 end)

      assert s1.time_ms == 1
      assert s2.time_ms == 2.2
      assert round(s3.time_ms) in 10..11
      assert round(s4.time_ms) in 5..7
    end
  end

  describe "counter" do
    test "records counts" do
      Stats.counter(:hotel_req, %{key: "dan"}, 2, StatsStore)
      assert_received {:counter, :hotel_req, 2, ["key:dan"]}
    end
  end

  describe "gauge" do
    test "records counts" do
      Stats.gauge(:hotel_req, %{key: "dan"}, 2.5, StatsStore)
      assert_received {:gauge, :hotel_req, 2.5, ["key:dan"]}
    end
  end

  describe "histogram" do
    test "records distribution of a histogram" do
      Stats.histogram(:hotel_req, 100, %{key: "dan"}, StatsStore)
      Stats.histogram(:hotel_req, 120, %{key: "z"}, StatsStore)
      assert_received {:histogram, :hotel_req, 100, ["key:dan"]}
      assert_received {:histogram, :hotel_req, 120, ["key:z"]}
    end
  end
end

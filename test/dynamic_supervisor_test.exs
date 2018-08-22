defmodule GrncShared.DynamicSupervisorTest do
  use ExUnit.Case, async: false
  alias GrncShared.DynamicSupervisor
  alias GrncShared.DynamicSupervisor.Spec

  def uniq_ids(n), do: Enum.map 1..n, fn _ -> System.unique_integer [:positive, :monotonic] end
  def assert_received_ids(ids), do: Enum.each(ids, fn message -> assert_received ^message end)

  def cb_fn_wrapper(args) do
    fn ->
      [args]
    end
  end

  defmodule Worker do
    def work(sleep_time, caller_pid, message) do
      :timer.sleep(sleep_time)
      send(caller_pid, message)
    end
  end

  test "start executes mfa" do
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([5, self(), :done])}],
      soft_timeout_ms: 10})

    DynamicSupervisor.wait(sup_handle)

    assert_received :done
  end

  test "start executes multiple mfcs" do
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([50, self(), :bar])}, {Worker, :work, cb_fn_wrapper([50, self(), :foo])}],
      soft_timeout_ms: 60})

    refute_received :foo
    refute_received :bar

    DynamicSupervisor.wait(sup_handle)

    assert_received :foo
    assert_received :bar
  end

  test "wait returns on soft_timeout" do
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([20, self(), :done])}],
      soft_timeout_ms: 10})

    refute_received :done
    DynamicSupervisor.wait(sup_handle)
    refute_received :done

    assert_receive :done, 10
  end

  test "supervisor is killed after all processes finish" do
    pid = self()
    after_complete_callback = fn -> send pid, :done end
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([10, self(), :pass])},
                                                      {Worker, :work, cb_fn_wrapper([20, self(), :fail])}],
      soft_timeout_ms: 20, after_complete_callback: after_complete_callback})

    refute_received :done
    DynamicSupervisor.wait(sup_handle)
    assert_receive :done, 20
    refute Process.alive?(sup_handle.sup_pid)
  end

  defmodule ErrorWorker do
    def work do
      raise "An error occured"
    end
  end

  test "failure in worker should not stop other workers" do
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([10, self(), :pass])},
                                            {ErrorWorker, :work, cb_fn_wrapper([])}],
       soft_timeout_ms: 30})

    DynamicSupervisor.wait(sup_handle)
    assert_received :pass
  end

  test "returns immediately if worker crashes" do
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{ErrorWorker, :work, cb_fn_wrapper([])}],
       soft_timeout_ms: 30})

    ref = sup_handle.wait_ref
    assert_receive {:ok, ^ref}, 10
  end

  test "returns immediately if worker finishes soon" do
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([0, self(), :pass])}],
       soft_timeout_ms: 30})

    ref = sup_handle.wait_ref
    assert_receive {:ok, ^ref}, 10
    assert_received :pass
  end

  @tag :slow
  test "allows spawning a 100 workers" do
    Task.async(fn ->
      ids = uniq_ids(100)
      mfcs = Enum.map(ids, & {Worker, :work, cb_fn_wrapper([div(&1, 10), self(), &1])})
      sup_handle = DynamicSupervisor.start(%Spec{mfcs: mfcs,
         soft_timeout_ms: 30})

        DynamicSupervisor.wait(sup_handle)
        assert_received_ids ids
    end) |> Task.await
  end

  def inspect_processes do
    IO.puts "PCOUNT: #{Process.list|>Enum.count}"
    :timer.sleep(1)
    inspect_processes()
  end

  defmodule BusyWorker do
    def work(sleep_ms, caller_pid, message) do
      #IO.puts "S#{message}"
      :timer.sleep(sleep_ms)
      send(caller_pid, message)
      #IO.puts "F#{message}"
      message
    end
  end

  @tag timeout: :infinity
  @tag :slow
  test "allows spawning a 500 supervisors and 50_0000 workers" do
    Enum.map(1..500, fn _sup_idx ->

      Task.async(fn ->
        ids = uniq_ids(500)

        pid = self()
        mfcs = Enum.map(ids, & {BusyWorker, :work, cb_fn_wrapper([10, pid, &1])})
        sup_handle = DynamicSupervisor.start(%Spec{mfcs: mfcs,
           soft_timeout_ms: 1000})

        DynamicSupervisor.wait(sup_handle)

        assert_received_ids ids
      end)

    end)
    |> Enum.map(fn t -> Task.await(t, 100_000) end)
  end


  test "processes should not be killed after soft timeout" do
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([10, self(), :done])}],
      soft_timeout_ms: 1})

    DynamicSupervisor.wait(sup_handle)

    assert_receive :done, 10
  end

  test "after complete callback should be called after processes finish" do
    pid = self()
    after_complete_callback = fn -> send pid, :complete_callback end

    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([10, self(), :done])}],
      soft_timeout_ms: 1, after_complete_callback: after_complete_callback})

    DynamicSupervisor.wait(sup_handle)

    assert_receive :complete_callback, 10
  end

  test "callback should work if one of worker crashes" do
    pid = self()
    after_complete_callback = fn -> send pid, :complete_callback end

    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([10, self(), :done])}, {ErrorWorker, :work, cb_fn_wrapper([])}],
       soft_timeout_ms: 30, after_complete_callback: after_complete_callback})

    DynamicSupervisor.wait(sup_handle)

    assert_received :complete_callback
    assert_received :done
  end

  test "supervisor is not stopped till tasks finish" do

    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn_wrapper([10, self(), :done])}, {ErrorWorker, :work, cb_fn_wrapper([])}],
       soft_timeout_ms: 1})

    DynamicSupervisor.wait(sup_handle)

    :timer.sleep(5)

    assert Process.alive?(sup_handle.sup_pid)
  end


  test "start executes for multiple generated args" do
    pid = self()
    cb_fn = fn ->
      [
        [5, pid, :done5],
        [15, pid, :done15],
        [25, pid, :done25],
      ]
    end
    sup_handle = DynamicSupervisor.start(%Spec{mfcs: [{Worker, :work, cb_fn}],
      soft_timeout_ms: 10})

    DynamicSupervisor.wait(sup_handle)

    assert_received :done5
    assert_receive :done15, 10
    assert_receive :done25, 10
  end

end

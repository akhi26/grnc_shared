defmodule GrncShared.DynamicSupervisor do
  @moduledoc """
  DynamicSupervisor can be used to spawn parallel asynchronous tasks

  It can be used as below:

      sup_handle = DynamicSupervisor.start(%Spec{
        mfcs: [
          # this needs to be a 3 term tuple containing the module, function and argument_generator_callback
          # the argument_generator_callback is a function fn () -> [[arg1, arg2], [arg1, arg2], ...]
          {GTA, :price_and_availability, argument_generator_callback},
          {HotelBeds, :price_and_availability, argument_generator_callback},
          # ...
        ],
        soft_timeout_ms: 30_000,
        after_complete_callback: fn() -> #stuff end
      })


      # this waits for soft_timeout_ms milliseconds and then returns
      # the workers may still be running after this returns
      # we call the after_complete_callback once all the processes have finished
      DynamicSupervisor.wait(sup_handle)

  """

  require Logger

  alias DynamicSupervisor.Spec
  alias DynamicSupervisor.Handle
  alias DynamicSupervisor.State

  defmodule Handle do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct wait_ref: nil, sup_pid: nil
  end

  defmodule Spec do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct mfcs: [], soft_timeout_ms: 0, after_complete_callback: &Spec.noop/0

    def noop, do: :ok
  end

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{}
    defstruct sup_pid: nil,
      calling_pid: nil,
      soft_timeout_ref: nil,
      soft_timer: nil,
      wait_ref: nil,
      after_complete_callback: &Spec.noop/1

  end

  @doc """
  Read the module documentation for more info
  """
  def start(%Spec{mfcs: mfcs, soft_timeout_ms:
    soft_timeout_ms, after_complete_callback: after_complete_callback}) do

    calling_pid = self() # request process
    wait_ref = make_ref()

    Task.async(fn ->
      process(calling_pid, wait_ref, mfcs, soft_timeout_ms, after_complete_callback)
    end)

    receive do
      {:sup_pid, sup_pid} -> %Handle{wait_ref: wait_ref, sup_pid: sup_pid}
    end

  end

  @doc """
  Read the module documentation for more info
  """
  def wait(%Handle{wait_ref: wait_ref}, timeout_ms \\ 90_000) do
    receive do
      {:ok, ^wait_ref} ->
        :ok
    after timeout_ms ->
      :ok
    end
  end

  defp mfa_generator(m, f, argument_generator_cb, loop_pid) do
    Enum.each(argument_generator_cb.(), fn args ->
      spawn_task(loop_pid, {m, f, args})
    end)
  end

  defp spawn_task(loop_pid, mfa) do
    send(loop_pid, {:spawn_task, mfa})
  end

  defp process(calling_pid, wait_ref, mfcs, soft_timeout_ms, after_complete_callback) do
    {:ok, sup_pid} = Task.Supervisor.start_link()
    # send the sup_pid to the calling process so that it can be received
    send(calling_pid, {:sup_pid, sup_pid})

    soft_timeout_ref = make_ref()
    soft_timer = Process.send_after(self(), {:soft_timeout, soft_timeout_ref}, soft_timeout_ms)
    Process.flag(:trap_exit, true)

    loop_pid = self()

    tasks = Enum.map(mfcs, fn {m, f, cb_fn} ->
      Task.Supervisor.async(sup_pid, fn -> mfa_generator(m, f, cb_fn, loop_pid) end)
    end)

    state = %State{sup_pid: sup_pid,
      soft_timeout_ref: soft_timeout_ref,
      calling_pid: calling_pid, wait_ref: wait_ref,
      soft_timer: soft_timer,
      after_complete_callback: after_complete_callback
    }
    wait_for_tasks(state, tasks)

    notify_caller(state)
  end

  defp notify_caller(%State{calling_pid: calling_pid, wait_ref: wait_ref,
    soft_timer: soft_timer}) do
    send(calling_pid, {:ok, wait_ref})
    Process.cancel_timer(soft_timer)
  end

  defp wait_for_tasks(state, []) do
    stop_supervisor(state)
  end

  defp wait_for_tasks(%State{soft_timeout_ref: soft_timeout_ref,
    sup_pid: sup_pid} = state, tasks) do

    receive do
      {:spawn_task, {m, f, a}} ->
        task = Task.Supervisor.async(sup_pid, m, f, a)
        wait_for_tasks(state, [task | tasks])
      {:soft_timeout, ^soft_timeout_ref} ->
        notify_caller(state)
        wait_for_tasks(state, tasks)
      {ref, _result} ->
        wait_for_tasks(state, remove_tasks(tasks, ref))
      {:EXIT, _, _} ->
        wait_for_tasks(state, tasks)
      {:DOWN, ref, _, _, _} ->
        wait_for_tasks(state, remove_tasks(tasks, ref))
      oops ->
        Logger.warn("unexpected message: #{inspect oops}")
        wait_for_tasks(state, tasks)
    end
  end

  defp remove_tasks(tasks, ref) do
    Enum.reject(tasks, fn t -> t.ref == ref end)
  end

  defp stop_supervisor(%State{sup_pid: sup_pid,
    after_complete_callback: after_complete_callback}) do
    Supervisor.stop(sup_pid)
    after_complete_callback.()
  end

end

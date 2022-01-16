defmodule BuildPipeline.Server do
  use GenServer
  alias BuildPipeline.{BuildStepRunner, RunnerMessage}
  alias IO.ANSI

  @moduledoc false
  @default_genserver_options []

  def child_spec(setup, parent_pid, genserver_options \\ @default_genserver_options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{setup, parent_pid}, genserver_options]},
      restart: :temporary
    }
  end

  def start_link({setup, parent_pid}, genserver_options \\ @default_genserver_options) do
    GenServer.start_link(__MODULE__, {setup, parent_pid}, genserver_options)
  end

  @impl true
  def init({setup, parent_pid}) do
    %{build_pipeline: build_pipeline, setup: %{verbose: verbose, cwd: cwd}} = setup

    terminal_width = RunnerMessage.fetch_terminal_width()
    runners = init_waiting_runners(build_pipeline, cwd)

    state = %{
      runners: runners,
      parent_pid: parent_pid,
      runner_messages: print_runners_pending(runners, terminal_width),
      verbose: verbose,
      terminal_width: terminal_width
    }

    {:ok, state, {:continue, :start_runners}}
  end

  @impl true
  def handle_continue(:start_runners, state) do
    start_runners_if_able(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:start_runners, state) do
    start_runners_if_able(state)
    {:noreply, state}
  end

  def handle_cast({:runner_finished, runner_pid, result}, state) do
    state
    |> update_completed_runners(runner_pid, result)
    |> continue_unless_step_failed(runner_pid)
  end

  # https://stackoverflow.com/questions/11283625/overwrite-last-line-on-terminal
  def handle_cast({:runner_starting, runner_pid}, state) do
    command = state[:runners][runner_pid][:command]
    message = "#{ANSI.magenta()}#{command} [Running]#{ANSI.reset()}"

    {:noreply, RunnerMessage.print(state, runner_pid, message)}
  end

  @impl true
  def terminate(:normal, %{parent_pid: parent_pid} = state) do
    send(parent_pid, {:server_done, parse_result(state)})
  end

  defp print_runners_pending(runners, terminal_width) do
    runners
    |> Enum.map(fn {pid, build_step} -> {pid, build_step} end)
    |> Enum.sort(fn {_, %{order: order_1}}, {_, %{order: order_2}} -> order_1 <= order_2 end)
    |> Map.new(fn {pid, %{order: order, command: command}} ->
      order = order + 1

      message = "#{ANSI.light_magenta()}#{command} [Pending]#{ANSI.reset()}"
      runner_message = RunnerMessage.print_first(message, order, terminal_width)

      {pid, runner_message}
    end)
  end

  defp parse_result(%{runners: runners}) do
    build_pipeline =
      runners
      |> Enum.sort(fn {_, %{order: order_1}}, {_, %{order: order_2}} -> order_1 <= order_2 end)
      |> Enum.map(fn {_, build_step} -> build_step end)

    failed? = Enum.any?(build_pipeline, fn build_step -> build_step.status == :incomplete end)

    if failed? do
      %{build_pipeline: build_pipeline, result: :failure}
    else
      %{build_pipeline: build_pipeline, result: :success}
    end
  end

  defp update_completed_runners(state, runner_pid, result) do
    runners =
      Map.update!(state.runners, runner_pid, fn runner ->
        runner
        |> Map.merge(result)
        |> Map.put(:status, :complete)
      end)

    %{state | runners: runners}
  end

  defp continue_unless_step_failed(state, runner_pid) do
    case Map.fetch!(state.runners, runner_pid) do
      %{exit_code: 0} = result ->
        state
        |> print_runner_succeeded(result, runner_pid)
        |> start_runners_if_able()
        |> finished_if_all_runners_done()

      %{exit_code: _non_zero} = result ->
        state =
          state
          |> print_runner_failed(result, runner_pid)
          |> put_aborted_for_incomplete_runners_msg()
          |> print_runner_output(result)

        {:stop, :normal, state}
    end
  end

  defp print_runner_failed(%{verbose: false} = state, result, runner_pid) do
    message = runner_failed_duration_message(result)
    RunnerMessage.print(state, runner_pid, message)
  end

  defp print_runner_failed(%{verbose: true} = state, result, runner_pid) do
    message = runner_failed_duration_message(result)

    message = """
    #{ANSI.red()}---------------------------------------------------------------------
    #{message}

    #{result.output}
    #{ANSI.red()}---------------------------------------------------------------------#{ANSI.reset()}
    """

    RunnerMessage.print(state, runner_pid, message)
  end

  defp runner_failed_duration_message(result) do
    %{duration_in_microseconds: duration_in_microseconds, command: command} = result
    duration = duration_message(duration_in_microseconds)
    "#{ANSI.red()}#{command} [Failed in #{duration}] ✘ #{ANSI.reset()}"
  end

  defp print_runner_output(%{verbose: false} = state, result) do
    IO.puts(result.output)
    state
  end

  defp print_runner_output(%{verbose: true} = state, _result) do
    state
  end

  defp print_runner_succeeded(%{verbose: false} = state, result, runner_pid) do
    message = runner_finished_in_duration_message(result)
    RunnerMessage.print(state, runner_pid, message)
  end

  defp print_runner_succeeded(%{verbose: true} = state, result, runner_pid) do
    finished_message = runner_finished_in_duration_message(result)

    message = """
    #{ANSI.green()}---------------------------------------------------------------------
    #{finished_message}

    #{result.output}
    #{ANSI.green()}---------------------------------------------------------------------#{ANSI.reset()}
    """

    RunnerMessage.print(state, runner_pid, message)
  end

  defp runner_finished_in_duration_message(result) do
    %{duration_in_microseconds: duration_in_microseconds, command: command} = result
    duration = duration_message(duration_in_microseconds)
    "#{ANSI.green()}#{command} [Finished in #{duration}] ✔ #{ANSI.reset()}"
  end

  defp duration_message(duration_in_microseconds) do
    cond do
      duration_in_microseconds < 1000 ->
        "#{duration_in_microseconds} μs"

      duration_in_microseconds < 1_000_000 ->
        "#{round(duration_in_microseconds / 1000)} ms"

      duration_in_microseconds < 60_000_000 ->
        "#{Float.round(duration_in_microseconds / 1_000_000, 1)} s"

      true ->
        "#{round(duration_in_microseconds / 60_000_000)} min"
    end
  end

  defp put_aborted_for_incomplete_runners_msg(state) do
    Enum.reduce(state.runners, state, fn
      {_runner_pid, %{status: :complete}}, state ->
        state

      {runner_pid, %{command: command}}, state ->
        message = "#{ANSI.magenta()}#{ANSI.crossed_out()}#{command} [Aborted]#{ANSI.reset()}"
        RunnerMessage.print(state, runner_pid, message)
    end)
  end

  defp finished_if_all_runners_done(state) do
    if Enum.all?(state.runners, fn {_runner_pid, %{status: status}} -> status == :complete end) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp start_runners_if_able(state) do
    completed_runners = completed_runners_by_name(state.runners)

    Enum.each(state.runners, fn {runner_pid, _build_step} ->
      GenServer.cast(runner_pid, {:run_if_able, completed_runners})
    end)

    state
  end

  defp completed_runners_by_name(runners) do
    runners
    |> Enum.filter(fn
      {_runner_pid, %{status: :complete}} -> true
      _ -> false
    end)
    |> MapSet.new(fn {_runner_pid, %{build_step_name: build_step_name}} -> build_step_name end)
  end

  defp init_waiting_runners(build_pipeline, cwd) do
    Enum.reduce(build_pipeline, %{}, fn build_step, runners ->
      {:ok, runner_pid} = BuildStepRunner.start_link(build_step, self(), cwd)

      build_step = Map.put(build_step, :status, :incomplete)
      Map.put(runners, runner_pid, build_step)
    end)
  end
end

defmodule BuildPipeline.RunnerMessage do
  alias IO.ANSI
  alias BuildPipeline.Result
  @moduledoc false
  @padding 20

  def fetch_terminal_width do
    tput_exists?()
    |> Result.and_then(&fetch_terminal_width_with_tput/0)
    |> parse_tput_cols_output()
  end

  def print_first(message, order, terminal_width) do
    %{message: message, lines: lines} = pad_message_and_get_lines(message, terminal_width)

    print_on_next_line(message)

    %{message: message, lines: lines, order: order}
  end

  def print(%{verbose: false, terminal_width: :unknown} = state, _runner_pid, message) do
    print_on_next_line(message)
    state
  end

  def print(%{verbose: false, terminal_width: terminal_width} = state, runner_pid, message) do
    runner_message = Map.fetch!(state.runner_messages, runner_pid)
    %{order: order, lines: lines, message: old_message} = runner_message

    max_lines = max_runner_output_lines(state.runner_messages)
    # |> IO.inspect()

    # line_shift = max_lines - order + 1

    # IO.inspect(order)

    line_shift = line_shift(state.runner_messages, order)
    # |> IO.inspect()

    if should_print_runner_output?() do
      # IO.write(
      #  "\r#{ANSI.cursor_up(line_shift)}\r#{ANSI.clear_line()}#{message}#{ANSI.cursor_down(line_shift)}\r"
      # )
      # IO.write(
      #  "S\r#{ANSI.cursor_up(line_shift)}\r#{ANSI.clear_line()}#{order}X#{ANSI.cursor_down(line_shift)}\rE"
      # )
    end

    runner_message = %{order: order, message: old_message, lines: lines}
    %{state | runner_messages: Map.put(state.runner_messages, runner_pid, runner_message)}
  end

  def print(%{verbose: true} = state, _runner_pid, message) do
    print_on_next_line(message)
    state
  end

  defp pad_message_and_get_lines(message, :unknown) do
    %{message: message, lines: :unknown}
  end

  defp pad_message_and_get_lines("", _terminal_width) do
    %{message: "", lines: 1}
  end

  defp pad_message_and_get_lines(message, terminal_width) do
    message_length = String.length(message)

    div = div(message_length, terminal_width)
    rem = rem(message_length, terminal_width)

    line_count = if rem == 0, do: div, else: div + 1

    last_line_length = if rem == 0, do: message_length, else: rem

    space_until_edge = terminal_width - last_line_length

    if space_until_edge < @padding do
      %{message: message <> String.duplicate(" ", @padding), lines: line_count + 1}
    else
      %{message: message, lines: line_count}
    end
  end

  defp print_on_next_line(message) do
    if should_print_runner_output?() do
      IO.puts(message)
    end
  end

  defp max_runner_output_lines(runner_messages) do
    Enum.reduce(runner_messages, 0, fn {_pid, %{lines: lines}}, acc ->
      acc + lines
    end)
  end

  defp line_shift(runner_messages, order) do
    # max_runner_output_lines(runner_messages)
    Enum.reduce(runner_messages, 0, fn {_pid, %{lines: lines, order: this_order}}, acc ->
      if this_order >= order do
        acc + lines + 1
      else
        acc
      end
    end)
  end

  defp should_print_runner_output? do
    Application.get_env(:build_pipeline, :print_runner_output, true)
  end

  defp fetch_terminal_width_with_tput do
    System.cmd("tput", ["cols"])
  end

  defp parse_tput_cols_output({output, 0}) do
    output
    |> String.trim()
    |> Integer.parse()
    |> case do
      {cols, _} -> cols
      _ -> :unknown
    end
  end

  defp parse_tput_cols_output(_) do
    :unknown
  end

  defp tput_exists? do
    "whereis"
    |> System.cmd(["tput"])
    |> case do
      {_tput, 0} -> :ok
      _ -> :error
    end
  end
end

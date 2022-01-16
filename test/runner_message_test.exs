defmodule BuildPipeline.RunnerMessageTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias BuildPipeline.RunnerMessage

  @padding 20
  @extra_padding String.duplicate(" ", @padding)

  describe "print_first/3" do
    test "prints the message - if the terminal_width is unknown" do
      original_env = Application.get_env(:build_pipeline, :print_runner_output)
      Application.put_env(:build_pipeline, :print_runner_output, true)

      output =
        capture_io(fn ->
          RunnerMessage.print_first("the message", 1, :unknown)
        end)

      assert output =~ "the message"

      Application.put_env(:build_pipeline, :print_runner_output, original_env)
    end

    test "prints the message - if the terminal_width is known" do
      original_env = Application.get_env(:build_pipeline, :print_runner_output)
      Application.put_env(:build_pipeline, :print_runner_output, true)

      output =
        capture_io(fn ->
          RunnerMessage.print_first("the message", 1, 150)
        end)

      assert output =~ "the message"

      Application.put_env(:build_pipeline, :print_runner_output, original_env)
    end

    test "given a message and a terminal with, returns & prints the expected message" do
      assert %{lines: 3, order: 1} =
               RunnerMessage.print_first(String.duplicate("a", 150 * 3 - 21), 1, 150)
    end

    test "when messages are 20 chars or closer to using the full terminal width, force them to use an extra line, and adds padding to make it happen" do
      cases = [
        %{
          input_message: String.duplicate("a", 40),
          expected_message: String.duplicate("a", 40) <> @extra_padding,
          expected_lines: 2,
          terminal_width: 40,
          order: 1
        },
        %{
          input_message: String.duplicate("a", 21),
          expected_message: String.duplicate("a", 21) <> @extra_padding,
          expected_lines: 2,
          terminal_width: 40,
          order: 1
        },
        %{
          input_message: String.duplicate("a", 20),
          expected_message: String.duplicate("a", 20),
          expected_lines: 1,
          terminal_width: 40,
          order: 1
        },
        %{
          input_message: String.duplicate("a", 19),
          expected_message: String.duplicate("a", 19),
          expected_lines: 1,
          terminal_width: 40,
          order: 1
        },
        %{
          input_message: String.duplicate("a", 199),
          expected_message: String.duplicate("a", 199) <> @extra_padding,
          expected_lines: 3,
          terminal_width: 100,
          order: 1
        },
        %{
          input_message: "",
          expected_message: "",
          expected_lines: 1,
          terminal_width: 40,
          order: 1
        }
      ]

      Enum.each(cases, fn %{
                            input_message: input_message,
                            expected_message: expected_message,
                            expected_lines: expected_lines,
                            terminal_width: terminal_width,
                            order: order
                          } ->
        assert %{lines: ^expected_lines, order: ^order, message: ^expected_message} =
                 RunnerMessage.print_first(input_message, order, terminal_width)
      end)
    end

    test "given a message and an unknown terminal with, returns & prints the expected" do
      assert %{lines: :unknown, order: 1} = RunnerMessage.print_first("1234567890", 1, :unknown)
    end
  end
end

defmodule BuildPipeline do
  alias BuildPipeline.{CommandLineArguments, ConfigFile, Result, Server}
  @moduledoc false

  def main(command_line_args \\ []) do
    run(command_line_args)
  end

  defp run(command_line_args) do
    command_line_args
    |> preflight_checks()
    |> run_if_preflight_checks_passed()
  end

  defp preflight_checks(command_line_args) do
    command_line_args
    |> CommandLineArguments.parse()
    |> Result.and_then(&ConfigFile.read/1)
    |> Result.and_then(&ConfigFile.parse_and_validate/1)
  end

  defp run_if_preflight_checks_passed({:ok, setup}) do
    children = [Server.child_spec(setup, self())]

    {:ok, supervisor_pid} = Supervisor.start_link(children, strategy: :one_for_one)

    receive do
      {:server_done, _result} -> Supervisor.stop(supervisor_pid)
    end
  end

  defp run_if_preflight_checks_passed({:error, error}) do
    case error do
      {:bad_cmd_args, bad_cmd_args, usage_instructions} ->
        IO.puts(
          "There was at least one bad argument in the command line arguments that you gave me:\n" <>
            "#{bad_cmd_args}\n" <>
            "#{usage_instructions}"
        )

      {:invalid_config, error_message} ->
        IO.puts(error_message)

      {:config_file_not_found, bad_config_file_path} ->
        IO.puts(
          "I failed to find a config.json file in the place you told me to look '#{bad_config_file_path}'"
        )

      %Jason.DecodeError{} ->
        IO.puts("I failed to parse the config.json because it was not valid JSON")
    end

    :error
  end
end

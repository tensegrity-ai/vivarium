defmodule Keeper.Sprites do
  @moduledoc """
  Client for the Sprites API. Uses HTTP when SPRITES_TOKEN is available,
  falls back to the `sprite` CLI otherwise.
  """

  require Logger

  @base_url "https://api.sprites.dev"
  @sprite_bin "sprite"
  @max_retries 2

  # -- Public API --

  def create(name) do
    if http?() do
      case post("/v1/sprites", json: %{name: name}) do
        {:ok, %{status: status}} when status in [200, 201] -> {:ok, name}
        {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{body_string(body)}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      cli(["create", "-o", org(), "--skip-console", name])
    end
  end

  def exec(name, command, opts \\ []) do
    if http?() do
      env_params =
        opts |> Keyword.get(:env, []) |> Enum.map(fn {k, v} -> {"env", "#{k}=#{v}"} end)

      params = [{"cmd", "bash"}, {"cmd", "-c"}, {"cmd", command}] ++ env_params

      case post("/v1/sprites/#{name}/exec", params: params, receive_timeout: 600_000) do
        {:ok, %{status: 200, body: body}} ->
          {stdout, stderr, exit_code} = extract_exec_output(body)

          if exit_code == 0 do
            {:ok, stdout}
          else
            detail = if stderr != "", do: stderr, else: stdout
            {:error, "exit #{exit_code}: #{detail}"}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{body_string(body)}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      env = Keyword.get(opts, :env, [])
      env_args = Enum.flat_map(env, fn {k, v} -> ["--env", "#{k}=#{v}"] end)
      cli(["exec", "-s", name, "-o", org()] ++ env_args ++ ["--", "bash", "-c", command])
    end
  end

  def checkpoint(name, opts \\ []) do
    if http?() do
      body =
        case Keyword.get(opts, :comment) do
          nil -> %{}
          comment -> %{comment: comment}
        end

      case post("/v1/sprites/#{name}/checkpoint", json: body, receive_timeout: 120_000) do
        {:ok, %{status: status, body: resp_body}} when status in [200, 201] ->
          {:ok, parse_checkpoint_response(resp_body)}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, "HTTP #{status}: #{body_string(resp_body)}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      cli(["checkpoint", "create", "-s", name, "-o", org()])
    end
  end

  def list_checkpoints(name) do
    if http?() do
      case get("/v1/sprites/#{name}/checkpoints") do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{body_string(body)}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      cli(["checkpoint", "list", "-s", name, "-o", org()])
    end
  end

  def restore(name, version) do
    if http?() do
      case post("/v1/sprites/#{name}/checkpoints/#{version}/restore", receive_timeout: 120_000) do
        {:ok, %{status: status}} when status in [200, 201] -> {:ok, "restored"}
        {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{body_string(body)}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      cli(["restore", version, "-s", name, "-o", org()])
    end
  end

  def destroy(name) do
    if http?() do
      case request(:delete, "/v1/sprites/#{name}") do
        {:ok, %{status: status}} when status in [200, 204] -> {:ok, "destroyed"}
        {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{body_string(body)}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      cli(["destroy", name, "-o", org(), "--force"])
    end
  end

  @doc "Write a file into the sprite via the filesystem API."
  def write_file(name, path, content) do
    if http?() do
      case request(:put, "/v1/sprites/#{name}/fs/write",
             params: [{"path", path}, {"mkdir", "true"}],
             body: content,
             headers: [{"content-type", "application/octet-stream"}]
           ) do
        {:ok, %{status: status}} when status in [200, 201, 204] -> {:ok, "written"}
        {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{body_string(body)}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      encoded = Base.encode64(content)
      dir = Path.dirname(path)
      exec(name, "mkdir -p #{dir} && echo '#{encoded}' | base64 -d > #{path}")
    end
  end

  @doc "Read a file from the sprite via the filesystem API."
  def read_file(name, path) do
    if http?() do
      case get("/v1/sprites/#{name}/fs/read", params: [{"path", path}]) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %{status: 200, body: body}} -> {:ok, body_string(body)}
        {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{body_string(body)}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      exec(name, "cat #{path}")
    end
  end

  # -- HTTP internals --

  defp http? do
    token() != nil
  end

  defp token do
    Application.get_env(:keeper, :sprites_token) || System.get_env("SPRITES_TOKEN")
  end

  defp org do
    Application.get_env(:keeper, :sprites_org, "tensegrity-systems")
  end

  defp client do
    Req.new(
      base_url: @base_url,
      headers: [{"authorization", "Bearer #{token()}"}],
      retry: :transient,
      max_retries: 3,
      retry_delay: fn attempt -> attempt * 1_000 end
    )
  end

  defp get(path, opts \\ []) do
    Req.get(client(), [url: path] ++ opts)
  end

  defp post(path, opts) do
    Req.post(client(), [url: path] ++ opts)
  end

  defp request(method, path, opts \\ []) do
    Req.request(client(), [method: method, url: path] ++ opts)
  end

  # The HTTP POST exec endpoint returns binary-framed output:
  # 0x01 = stdout, 0x02 = stderr, 0x03 + byte = exit code
  defp extract_exec_output(body) when is_binary(body) do
    {stdout, stderr, exit_code} = parse_exec_frames(body)
    {String.trim(stdout), String.trim(stderr), exit_code}
  end

  defp extract_exec_output(%{"output" => output}), do: {String.trim(output), "", 0}
  defp extract_exec_output(%{"stdout" => stdout}), do: {String.trim(stdout), "", 0}
  defp extract_exec_output(body) when is_map(body), do: {inspect(body), "", 0}
  defp extract_exec_output(body), do: {to_string(body), "", 0}

  defp parse_exec_frames(data) do
    parse_exec_frames(data, <<>>, <<>>, 0)
  end

  # Collect stdout (0x01), stderr (0x02), and exit code (0x03)
  defp parse_exec_frames(<<>>, stdout, stderr, exit_code), do: {stdout, stderr, exit_code}

  defp parse_exec_frames(<<0x01, rest::binary>>, stdout, stderr, exit_code),
    do: collect_stdout(rest, stdout, stderr, exit_code)

  defp parse_exec_frames(<<0x02, rest::binary>>, stdout, stderr, exit_code),
    do: collect_stderr(rest, stdout, stderr, exit_code)

  defp parse_exec_frames(<<0x03, code, rest::binary>>, stdout, stderr, _exit_code),
    do: parse_exec_frames(rest, stdout, stderr, code)

  defp parse_exec_frames(<<byte, rest::binary>>, stdout, stderr, exit_code),
    do: parse_exec_frames(rest, <<stdout::binary, byte>>, stderr, exit_code)

  # Collect bytes until we hit another frame marker (0x01, 0x02, 0x03)
  defp collect_stdout(<<>>, stdout, stderr, exit_code), do: {stdout, stderr, exit_code}

  defp collect_stdout(<<marker, _::binary>> = rest, stdout, stderr, exit_code)
       when marker in [0x01, 0x02, 0x03],
       do: parse_exec_frames(rest, stdout, stderr, exit_code)

  defp collect_stdout(<<byte, rest::binary>>, stdout, stderr, exit_code),
    do: collect_stdout(rest, <<stdout::binary, byte>>, stderr, exit_code)

  defp collect_stderr(<<>>, stdout, stderr, exit_code), do: {stdout, stderr, exit_code}

  defp collect_stderr(<<marker, _::binary>> = rest, stdout, stderr, exit_code)
       when marker in [0x01, 0x02, 0x03],
       do: parse_exec_frames(rest, stdout, stderr, exit_code)

  defp collect_stderr(<<byte, rest::binary>>, stdout, stderr, exit_code),
    do: collect_stderr(rest, <<stdout::binary, byte>>, stderr, exit_code)

  defp parse_checkpoint_response(body) when is_binary(body) do
    # NDJSON — parse last complete line for the checkpoint result
    body
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil ->
        body

      line ->
        case Jason.decode(line) do
          {:ok, %{"id" => _} = data} -> data
          {:ok, data} -> data
          _ -> body
        end
    end
  end

  defp parse_checkpoint_response(%{"id" => _} = body), do: body
  defp parse_checkpoint_response(body), do: body

  defp body_string(body) when is_binary(body), do: body
  defp body_string(body) when is_map(body), do: Jason.encode!(body)
  defp body_string(body), do: inspect(body)

  # -- CLI fallback --

  defp cli(args) do
    do_cli(@sprite_bin, args, 0)
  end

  defp do_cli(program, args, attempt) do
    case System.cmd(program, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _code} ->
        if attempt < @max_retries and String.contains?(output, "502") do
          Process.sleep(1_000 * (attempt + 1))
          do_cli(program, args, attempt + 1)
        else
          {:error, String.trim(output)}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end

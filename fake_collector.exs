# Minimal fake OTLP/HTTP collector.
#
# Listens on PORT (default 4318), accepts POSTs to /v1/traces, replies
# 200 with an empty protobuf body, and prints what it received. Span
# names travel as plain bytes inside the protobuf payload, so a substring
# scan is enough to assert which spans arrived without pulling in a
# protobuf decoder.

port = String.to_integer(System.get_env("PORT", "4318"))

defmodule FakeCollector do
  def serve(listen) do
    {:ok, sock} = :gen_tcp.accept(listen)
    handle(sock)
    serve(listen)
  end

  defp handle(sock) do
    with {:ok, header_data} <- read_headers(sock, "") do
      [request_line | header_lines] = String.split(header_data, "\r\n")

      content_length =
        header_lines
        |> Enum.find_value(0, fn line ->
          case String.split(String.downcase(line), "content-length:") do
            [_, len] -> len |> String.trim() |> String.to_integer()
            _ -> nil
          end
        end)

      body = read_body(sock, content_length)

      markers =
        [
          "GET /items",
          "vanilla_app.repo.query",
          "items",
          "vanilla-app-spike",
          "vanilla-app-erlang-spike",
          "internal.invalid",
          "process default"
        ]
        |> Enum.filter(&String.contains?(body, &1))

      # Each exported HTTP-server span carries its operation name once, so
      # counting occurrences of "GET /items" approximates the number of
      # distinct request spans in this batch — used by run_spike.sh's race
      # window diagnostic to see how many of N concurrent startup requests
      # actually got traced.
      span_count =
        body
        |> String.split("GET /items")
        |> length()
        |> Kernel.-(1)
        |> max(0)

      IO.puts(
        "[collector] #{request_line} body=#{byte_size(body)} bytes " <>
          "span_count=#{span_count} markers=#{inspect(markers)}"
      )

      :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
      :gen_tcp.close(sock)
    end
  end

  defp read_headers(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc |> String.split("\r\n\r\n") |> hd()}
    else
      case :gen_tcp.recv(sock, 0, 10_000) do
        {:ok, data} ->
          acc = acc <> data

          if String.contains?(acc, "\r\n\r\n") do
            [headers, rest] = String.split(acc, "\r\n\r\n", parts: 2)
            Process.put(:body_prefix, rest)
            {:ok, headers}
          else
            read_headers(sock, acc)
          end

        error ->
          error
      end
    end
  end

  defp read_body(sock, content_length) do
    prefix = Process.get(:body_prefix, "")
    read_body_loop(sock, prefix, content_length)
  end

  defp read_body_loop(_sock, acc, len) when byte_size(acc) >= len, do: acc

  defp read_body_loop(sock, acc, len) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> read_body_loop(sock, acc <> data, len)
      _ -> acc
    end
  end
end

{:ok, listen} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
IO.puts("[collector] listening on #{port}")
FakeCollector.serve(listen)

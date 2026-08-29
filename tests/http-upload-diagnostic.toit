// Copyright (C) 2026 Toitware ApS. All rights reserved.

import host.pipe
import http
import monitor
import net

import ..tools.http-servers.public.broker.base show TimingReader
import ..tools.lan-ip.lan-ip

// Matches the large pod part observed in cmd-pod-list-test-slow.
BODY-SIZE ::= 23_417_108
ATTEMPTS ::= 20

main args/List:
  if args.is-empty:
    throw "Expected one of: same, separate, server"

  mode := args[0]
  if mode == "server":
    request-count := args.size >= 2 ? int.parse args[1] : 1
    run-server --request-count=request-count: | host/string port/int |
      print "$host:$port"
    return

  attempts := args.size >= 2 ? int.parse args[1] : ATTEMPTS
  toit-executable := args.size >= 3 ? args[2] : "toit"
  source-path := args.size >= 4 ? args[3] : "tests/http-upload-diagnostic.toit"
  project-root := args.size >= 5 ? args[4] : "tests"
  body := ByteArray BODY-SIZE --initial=0xa5

  if mode == "same":
    run-server --request-count=attempts: | host/string port/int |
      run-client-attempts body host port --mode=mode --attempts=attempts
  else if mode == "separate":
    run-separate body
        --toit-executable=toit-executable
        --source-path=source-path
        --project-root=project-root
        --attempts=attempts
  else:
    throw "Unknown mode '$mode'"

run-server --request-count/int [ready]:
  network := net.open
  server-socket := network.tcp-listen 0
  host := get-lan-ip
  port := server-socket.local-address.port
  server := http.Server --max-tasks=64
  request-done := monitor.Latch
  server-done := monitor.Latch
  remaining-requests := request-count

  task::
    try:
      server.listen server-socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
        try:
          total-size := request.content-length
          if not total-size: throw "Expected Content-Length"
          request-index := request-count - remaining-requests + 1
          request-id := "diagnostic POST /upload attempt $request-index/$request-count"
          reader := TimingReader request.body request-id total-size
          received := reader.read-all
          if received.size != total-size:
            throw "Expected $total-size bytes, received $received.size"
          writer.out.write "ok"
          writer.close
        finally:
          remaining-requests--
          if remaining-requests == 0: request-done.set true
    finally:
      server-done.set true

  try:
    ready.call host port
    request-done.get
  finally:
    server.close
    server-socket.close
    server-done.get
    network.close

run-client-attempts body/ByteArray host/string port/int --mode/string --attempts/int:
  network := net.open
  client := http.Client network
  try:
    attempts.repeat: | index/int |
      attempt := index + 1
      print-on-stderr_ "HTTP diagnostic $mode attempt $attempt/$attempts"
      start-us := Time.monotonic-us
      response := client.request http.POST body
          --uri="http://$host:$port/upload"
          --content-type="application/octet-stream"
      elapsed-ms := (Time.monotonic-us - start-us) / 1_000
      response-body := response.body.read-all.to-string
      if response.status-code != http.STATUS-OK or response-body != "ok":
        throw "Unexpected HTTP response: $response.status-code '$response-body'"
      print-on-stderr_
          "HTTP diagnostic result mode=$mode attempt=$attempt/$attempts server=$host:$port bytes=$body.size elapsed=$(elapsed-ms)ms"
  finally:
    client.close
    network.close

run-separate body/ByteArray
    --toit-executable/string
    --source-path/string
    --project-root/string
    --attempts/int:
  process := pipe.fork
      --create-stdout
      toit-executable
      [
        toit-executable,
        "run",
        "--project-root",
        project-root,
        source-path,
        "--",
        "server",
        "$attempts",
      ]
  stdout := process.stdout
  if not stdout: throw "Failed to capture diagnostic server output"

  completed := false
  try:
    endpoint := stdout.in.read-line
    if not endpoint: throw "Diagnostic server exited before announcing its port"
    endpoint-parts := endpoint.split ":"
    if endpoint-parts.size != 2: throw "Invalid diagnostic server endpoint '$endpoint'"
    host := endpoint-parts[0]
    port := int.parse endpoint-parts[1]
    run-client-attempts body host port --mode="separate" --attempts=attempts

    process.wait
    if process.exit-code != 0:
      throw "Diagnostic server exited with code $process.exit-code"
    completed = true
  finally:
    if not completed:
      catch: process.kill --wait --hard-after-ms=1_000
    stdout.close

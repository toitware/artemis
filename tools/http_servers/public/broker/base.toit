// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import encoding.json
import http
import io
import log
import net
import net.tcp
import monitor
import system

BODY-PROGRESS-INTERVAL_ ::= 1 * 1024 * 1024

class TimingReader_ extends io.Reader:
  reader_/io.Reader
  request-id_/string
  total-size_/int
  read-size_/int := 0
  chunk-count_/int := 0
  next-report_/int := BODY-PROGRESS-INTERVAL_
  last-report-us_/int := Time.monotonic-us
  last-report-chunk-count_/int := 0
  finished_/bool := false

  constructor .reader_ .request-id_ .total-size_:

  read_ -> ByteArray?:
    data := reader_.read
    if not data:
      if not finished_:
        finished_ = true
        report_ "finished"
      return null

    read-size_ += data.size
    chunk-count_++
    if read-size_ >= next-report_:
      report_ "progress"
      next-report_ = ((read-size_ / BODY-PROGRESS-INTERVAL_) + 1) * BODY-PROGRESS-INTERVAL_
    return data

  report_ phase/string -> none:
    now-us := Time.monotonic-us
    elapsed-ms := (now-us - last-report-us_) / 1_000
    chunks := chunk-count_ - last-report-chunk-count_
    stats := system.process-stats
    message := "$Time.now: HTTP server body $phase $request-id_: "
    message += "$read-size_/$total-size_ bytes, $chunks chunks in $(elapsed-ms)ms, "
    message += "GC $(stats[system.STATS-INDEX-GC-COUNT])/$(stats[system.STATS-INDEX-FULL-GC-COUNT]), "
    message += "heap $(stats[system.STATS-INDEX-ALLOCATED-MEMORY])/$(stats[system.STATS-INDEX-RESERVED-MEMORY])"
    print-on-stderr_ message
    last-report-us_ = now-us
    last-report-chunk-count_ = chunk-count_

class BinaryResponse:
  bytes/ByteArray
  total-size/int

  constructor .bytes .total-size:

abstract class HttpServer:
  port/int? := null
  debug-timing_/bool

  socket_/tcp.ServerSocket? := null

  /**
  List of listeners.
  Each lambda in this list is called twice for each command:
  1. Once befor the command is executed, with ("pre", <command>, data).
  2. After the command finished, with ("post", <command>, <result>), or ("error", <command>, <error>).

  Typically, listeners are only used in tests.
  */
  listeners/List := []

  constructor .port --debug-timing/bool=false:
    debug-timing_ = debug-timing

  debug-timing_ message/string -> none:
    if debug-timing_:
      print-on-stderr_ "$Time.now: $message"

  close:
    if socket_:
      socket_.close
      socket_ = null

  abstract run-command command/int encoded/ByteArray user-id/string? -> any

  /** Handles the conventional interface-oriented API used by new CLIs. */
  run-request method/string path/string query/Map body/ByteArray headers/http.Headers user-id/string? -> any:
    throw "Conventional API not supported"

  /**
  Starts the server in a blocking way.

  Sets the given $port-latch with the value of the port on which the server is
    listening.
  */
  start port-latch/monitor.Latch?=null:
    network := net.open
    socket := network.tcp-listen (port or 0)
    port = socket.local-address.port
    if port-latch: port-latch.set port
    server := http.Server --max-tasks=64 --logger=(log.default.with-level log.INFO-LEVEL)
    print "Listening on port $socket.local-address.port"
    server.listen socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
      user-id := request.headers.single "X-User-Id"
      if not request.headers.single "X-Artemis-Header":
        throw "Missing X-Artemis-Header"

      resource := request.query.resource
      content-length := request.content-length
      debug-timing_ "HTTP server reading $request.method $resource with Content-Length $content-length"
      body/io.Reader := request.body
      if debug-timing_ and content-length and content-length >= BODY-PROGRESS-INTERVAL_:
        body = TimingReader_ body "$request.method $resource" content-length
      bytes := body.read-all
      debug-timing_ "HTTP server read $bytes.size bytes for $request.method $resource"
      if resource == "/":
        command := bytes[0]
        encoded := bytes[1..]
        listeners.do: it.call "pre" command encoded user-id
        reply_ command writer --legacy=true:
          run-command command encoded user-id
      else:
        listeners.do: it.call "pre" resource bytes user-id
        reply_ resource writer --legacy=false:
          run-request
              request.method
              resource
              request.query.parameters
              bytes
              request.headers
              user-id

  reply_ request-id/any writer/http.ResponseWriter --legacy/bool [block]:
    start-us := Time.monotonic-us
    debug-timing_ "HTTP server handling $request-id"
    response-data := null
    exception := catch --trace:
      with-timeout --ms=3_000:
        response-data = block.call
    if exception:
      elapsed-ms := (Time.monotonic-us - start-us) / 1_000
      debug-timing_ "HTTP server failed $request-id after $(elapsed-ms)ms: $exception"
      listeners.do: it.call "error" request-id exception
      encoded-response := legacy
          ? json.encode exception
          : json.encode {"message": "$exception"}
      writer.headers.set "Content-Length" "$encoded-response.size"
      writer.write-headers (legacy ? http.STATUS-IM-A-TEAPOT : http.STATUS-INTERNAL-SERVER-ERROR) --message="Error"
      writer.out.write encoded-response
    else:
      elapsed-ms := (Time.monotonic-us - start-us) / 1_000
      debug-timing_ "HTTP server handled $request-id after $(elapsed-ms)ms"
      listeners.do: it.call "post" request-id response-data
      if response-data is BinaryResponse:
        binary := response-data as BinaryResponse
        status := http.STATUS-OK
        if binary.bytes.size != binary.total-size:
          writer.headers.add "Content-Range" "$binary.bytes.size/$binary.total-size"
          status = http.STATUS-PARTIAL-CONTENT
        writer.headers.set "Content-Length" "$binary.bytes.size"
        writer.write-headers status
        writer.out.write binary.bytes
      else:
        encoded-response := json.encode response-data
        writer.headers.set "Content-Length" "$encoded-response.size"
        writer.out.write encoded-response

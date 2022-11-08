// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.pipe
import log
import monitor
import mqtt
import mqtt.transport as mqtt
import net

get_mosquitto_version:
  fork_data := pipe.fork
      true  // use_path.
      pipe.PIPE_INHERITED  // stdin.
      pipe.PIPE_CREATED    // stdout.
      pipe.PIPE_INHERITED  // stderr.
      "mosquitto"  // Program.
      ["mosquitto", "-h"]  // Args.
  stdout /pipe.OpenPipe := fork_data[1]
  out_data := #[]
  task::
    while chunk := stdout.read:
      out_data += chunk

  pipe.wait_for fork_data[3]
  out_str := out_data.to_string
  first_line /string := (out_str.split "\n").first
  return first_line.trim --left "mosquitto version "

start_mosquitto:
  port /string := pipe.backticks "python" "third_party/ephemeral-port-reserve/ephemeral_port_reserve.py"
  port = port.trim
  fork_data := pipe.fork
      true  // use_path.
      pipe.PIPE_INHERITED  // stdin.
      pipe.PIPE_CREATED  // stdout.
      pipe.PIPE_CREATED  // stderr.
      "mosquitto"  // Program.
      ["mosquitto", "-v", "-p", port]  // Args.
  return [
    int.parse port,
    fork_data
  ]

with_mosquitto --logger/log.Logger [block]:
  mosquitto_data := start_mosquitto
  port := mosquitto_data[0]
  logger.info "started mosquitto on port $port"

  mosquitto_fork_data := mosquitto_data[1]

  mosquitto_is_running := monitor.Latch
  stdout_bytes := #[]
  stderr_bytes := #[]
  task::
    stdout /pipe.OpenPipe := mosquitto_fork_data[1]
    while chunk := stdout.read:
      logger.debug chunk.to_string.trim
      stdout_bytes += chunk
  task::
    stderr /pipe.OpenPipe := mosquitto_fork_data[2]
    while chunk := stderr.read:
      str := chunk.to_string.trim
      logger.debug str
      stderr_bytes += chunk
      full_str := stderr_bytes.to_string
      if full_str.contains "Opening ipv6 listen socket on port":
        mosquitto_is_running.set true

  // Give mosquitto a second to start.
  // If it didn't start we might be looking for the wrong line in its output.
  // There was a change between 1.6.9 and 2.0.14. Could be that there is
  // going to be another one.
  with_timeout --ms=1_000:
    mosquitto_is_running.get

  network := net.open

  // Even though Mosquitto claims that it is listening (and in v2 it even claims
  // that it is "running"), that doesn't mean that it is ready for connections
  // yet.
  for i := 0; i < 10; i++:
    socket := null
    exception := catch:
      socket = network.tcp_connect "localhost" port
    if socket:
      socket.close
      break
    sleep --ms=(50*i)

  try:
    block.call {
      "host": "localhost",
      "port": port,
    }
  finally: | is_exception _ |
    pid := mosquitto_fork_data[3]
    logger.info "killing mosquitto server"
    pipe.kill_ pid 15
    pipe.wait_for pid
    if is_exception:
      print stdout_bytes.to_string
      print stderr_bytes.to_string

/**
Function to test with an external mosquitto.
Can sometimes be useful, as the logging is better.
*/
with_external_mosquitto --logger/log.Logger [block]:
  network := net.open
  block.call {
    "host": "localhost",
    "port": 1883,
  }

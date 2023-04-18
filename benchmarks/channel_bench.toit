// Copyright (C) 2023 Toitware ApS. All rights reserved.

import artemis.service.pkg_artemis_src_copy.artemis

main:
  bench_open_empty
  bench_open_full
  bench_send
  bench_receive

bench_open_empty:
  channel/artemis.Channel := artemis.Channel.open --topic="nisse" --receive
  drain channel
  channel.close
  bench_open "empty"

bench_open_full:
  channel/artemis.Channel := artemis.Channel.open --topic="nisse" --receive
  fill channel 1
  channel.close
  bench_open "full"

bench_open marker/string:
  channel/artemis.Channel? := null
  elapsed := Duration.of:
    channel = artemis.Channel.open --topic="nisse"
  channel.close
  print "open = $elapsed ($marker)"

bench_send:
  channel/artemis.Channel := artemis.Channel.open --topic="nisse" --receive
  drain channel

  worst/Duration? := null
  elapsed := Duration.of:
    1000.repeat:
      individual := Duration.of:
        channel.send #[1, 2, 3, 4, 5]
      if not worst or individual > worst: worst = individual
  channel.close
  print "send = $(elapsed / 1000)"
  print "send = $worst (worst)"

bench_receive:
  channel/artemis.Channel := artemis.Channel.open --topic="nisse" --receive
  e0 := Duration.of: drain channel
  print "draining = $e0"

  n := 0
  e1 := Duration.of: n = fill channel 10
  print "filling = $e1 ($n)"

  worst/Duration? := null
  n = 0
  elapsed := Duration.of:
    while true:
      element := null
      individual := Duration.of: element = channel.receive
      if not element: break
      if not worst or individual > worst: worst = individual
      n++
  channel.close
  print "receive = $(elapsed / n)"
  print "receive = $worst (worst)"

fill channel/artemis.Channel x/int -> int:
  n := 0
  bytes := ByteArray x: it
  catch --unwind=(: it != "OUT_OF_BOUNDS"):
    while true:
      channel.send bytes
      n++
  return n

drain channel/artemis.Channel:
  while not channel.is_empty:
    channel.receive
    n := channel.buffered
    n.repeat: channel.receive
    channel.acknowledge n + 1

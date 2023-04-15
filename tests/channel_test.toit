// Copyright (C) 2022 Toitware ApS.

import system.services
import expect show *

import artemis.service.pkg_artemis_src_copy.artemis
import artemis.service.pkg_artemis_src_copy.api
import artemis.service.channels show ChannelResource ChannelServiceProvider

main:
  provider := TestServiceProvider
  provider.install
  spawn:: test
  // Uninstall after waiting for the first client to connect
  // and the last client to disconnect.
  provider.uninstall --wait

test:
  channel := artemis.Channel.open --topic="fisk"
  1999.repeat: channel.send #[1, 2, 3, 4, 5]
  channel.close

  3.repeat: test_simple "fisk"
  test_multi "fisk"
  test_multi "hest"

test_simple topic/string:
  channel := artemis.Channel.open --topic=topic --receive
  drain_channel channel

  position := channel.position
  try:
    list := List 200: (ByteArray 60 + (random 40): random 0x100)
    list.do: channel.send it
    list.size.repeat:
      expect_equals (position + it) channel.position
      expect_bytes_equal list[it] channel.receive
      // Test the < and > operator.
      expect position < channel.position
      expect channel.position > position
    expect_null channel.receive
    expect_throw "OUT_OF_RANGE: 209 > 200": channel.acknowledge 209
    position = channel.position
    remaining := list.size
    while remaining > 0:
      n := 1 + (random remaining)
      channel.acknowledge n
      expect_equals position channel.position
      remaining -= n
    expect_throw "OUT_OF_RANGE: 1 > 0": channel.acknowledge
    expect_equals position channel.position
  finally:
    channel.close

test_multi topic/string:
  channel := artemis.Channel.open --topic=topic --receive
  expect_throw "ALREADY_IN_USE":
    artemis.Channel.open --topic=topic --receive
  drain_channel channel

  received := []
  try:
    5.repeat: | index |
      task::
        sender := artemis.Channel.open --topic=topic
        expect_throw "ALREADY_IN_USE":
          artemis.Channel.open --topic=topic --receive
        expect_throw "PERMISSION_DENIED":
          sender.receive
        expect_throw "OUT_OF_RANGE: 1 > 0":
          sender.acknowledge
        50.repeat:
          sender.send #[index, random 0x100]
          sleep --ms=2 + (random 7)
        sender.close
    (5 * 50).repeat:
      while channel.is_empty: sleep --ms=50
      received.add channel.receive.copy
      channel.acknowledge
    expect_throw "ALREADY_IN_USE":
      artemis.Channel.open --topic=topic --receive
  finally:
    channel.close

  5.repeat: | index |
    expect_equals 50 (received.filter: it[0] == index).size

drain_channel channel/artemis.Channel -> none:
  while not channel.is_empty:
    channel.receive
    n := channel.buffered
    n.repeat: channel.receive
    channel.acknowledge n + 1

// --------------------------------------------------------------------------

class TestServiceProvider extends ChannelServiceProvider
    implements services.ServiceHandlerNew:
  constructor:
    super "toit.io/test-artemis" --major=1 --minor=0
    provides api.ArtemisService.SELECTOR --handler=this --new

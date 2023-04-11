// Copyright (C) 2022 Toitware ApS.

import system.services
import expect show *

import artemis.service.pkg_artemis_src_copy.artemis
import artemis.service.pkg_artemis_src_copy.api
import artemis.service.channels show ChannelResource

main:
  provider := TestServiceProvider
  provider.install
  spawn:: test
  provider.uninstall --wait

test:
  channel := artemis.Channel.open --topic="fisk" --read
  1999.repeat: channel.send #[1, 2, 3, 4, 5]
  channel.close

  3.repeat: test_simple "fisk"
  test_multi "fisk"
  test_multi "hest"

test_simple topic/string:
  channel := artemis.Channel.open --topic=topic --read
  drain_channel channel

  position := channel.position
  try:
    list := List 200: (ByteArray 60 + (random 40): random 0x100)
    list.do: channel.send it
    list.size.repeat:
      expect_equals (position + it) channel.position
      expect_bytes_equal list[it] channel.receive
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
  channel := artemis.Channel.open --topic=topic --read
  expect_throw "ALREADY_IN_USE":
    artemis.Channel.open --topic=topic --read
  drain_channel channel

  received := []
  try:
    5.repeat: | index |
      task::
        sender := artemis.Channel.open --topic=topic
        expect_throw "ALREADY_IN_USE":
          artemis.Channel.open --topic=topic --read
        50.repeat:
          sender.send #[index, random 0x100]
          sleep --ms=2 + (random 7)
        sender.close
    (5 * 50).repeat:
      while channel.is_empty: sleep --ms=50
      received.add channel.receive.copy
      channel.acknowledge
    expect_throw "ALREADY_IN_USE":
      artemis.Channel.open --topic=topic --read
  finally:
    channel.close

  5.repeat: | index |
    count := received.reduce --initial=0: | acc x |
      x[0] == index ? acc + 1 : acc
    expect_equals 50 count

drain_channel channel/artemis.Channel -> none:
  while not channel.is_empty:
    channel.receive
    n := channel.buffered
    n.repeat: channel.receive
    channel.acknowledge n + 1

// --------------------------------------------------------------------------

// TODO(kasper): Share more code with the real Artemis implementation.
class TestServiceProvider extends services.ServiceProvider
    implements services.ServiceHandlerNew:
  constructor:
    super "toit.io/test-artemis" --major=1 --minor=0
    provides api.ArtemisService.SELECTOR --handler=this --new

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ArtemisService.CHANNEL_OPEN_INDEX:
      return channel_open client --topic=arguments[0] --read=arguments[1]
    if index == api.ArtemisService.CHANNEL_SEND_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.send arguments[1]
    if index == api.ArtemisService.CHANNEL_RECEIVE_PAGE_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.receive_page --peek=arguments[1] --buffer=arguments[2]
    if index == api.ArtemisService.CHANNEL_ACKNOWLEDGE_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.acknowledge arguments[1] arguments[2]
    unreachable

  channel_open client/int --topic/string --read/bool -> ChannelResource:
    return ChannelResource this client --topic=topic --read=read

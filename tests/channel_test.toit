// Copyright (C) 2022 Toitware ApS.

import system.services
import expect show *

import artemis.service.pkg_artemis_src_copy.artemis
import artemis.service.pkg_artemis_src_copy.api
import artemis.service.channels show ChannelResource

main:
  provider := TestServiceProvider
  provider.install
  spawn::
    test
  provider.uninstall --wait

test:
  channel := artemis.Channel.open --topic="fisk"
  try:
    channel.send #[1, 2, 3]
    expect_bytes_equal #[1, 2, 3] channel.receive
  finally:
    channel.close
// --------------------------------------------------------------------------

// TODO(kasper): Share more code with the real Artemis implementation.
class TestServiceProvider extends services.ServiceProvider
    implements services.ServiceHandlerNew:
  constructor:
    super "toit.io/test-artemis" --major=1 --minor=0
    provides api.ArtemisService.SELECTOR --handler=this --new

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ArtemisService.CHANNEL_OPEN_INDEX:
      return channel_open client --topic=arguments
    if index == api.ArtemisService.CHANNEL_SEND_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.send arguments[1]
    if index == api.ArtemisService.CHANNEL_RECEIVE_PAGE_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.receive_page --page=arguments[1] --buffer=arguments[2]
    if index == api.ArtemisService.CHANNEL_ACKNOWLEDGE_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.acknowledge arguments[1]
    unreachable

  channel_open client/int --topic/string -> ChannelResource:
    return ChannelResource this client --topic=topic

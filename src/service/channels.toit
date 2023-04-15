// Copyright (C) 2023 Toitware ApS. All rights reserved.

import system.services show ServiceResource ServiceProvider
import system.storage

import .flashlog show FlashLog SN
import .pkg_artemis_src_copy.api as api

flashlogs_ ::= {:}
receivers_ ::= {}

class ChannelResource extends ServiceResource:
  topic/string
  receive/bool
  log_/FlashLog? := ?

  constructor provider/ServiceProvider client/int --.topic --.receive:
    if receive:
      if receivers_.contains topic: throw "ALREADY_IN_USE"
      receivers_.add topic
    log_ = flashlogs_.get topic --init=:
      path := "toit.io/channel/$topic"
      capacity := 32 * 1024
      FlashLog (storage.Region.open --flash path --capacity=capacity)
    log_.acquire
    super provider client

  send bytes/ByteArray -> none:
    log_.append bytes

  receive_page --peek/int --buffer/ByteArray? -> List:
    if not receive: throw "PERMISSION_DENIED"
    buffer = buffer or (ByteArray log_.size_per_page_)
    return log_.read_page buffer --peek=peek

  acknowledge sn/int count/int -> none:
    if not receive: throw "PERMISSION_DENIED"
    if count < 1: throw "Bad Argument"
    log_.acknowledge (SN.previous (SN.next sn --increment=count))

  on_closed -> none:
    log := log_
    if not log: return
    log_ = null
    if receive: receivers_.remove topic
    if log.release == 0: flashlogs_.remove topic

class ChannelServiceProvider extends ServiceProvider:
  constructor name/string --major/int --minor/int:
    super name --major=major --minor=minor

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ArtemisService.CHANNEL_OPEN_INDEX:
      return channel_open client --topic=arguments[0] --receive=arguments[1]
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

  channel_open --topic/string --receive/bool -> int?:
    unreachable  // Here to satisfy the checker.

  channel_send handle/int bytes/ByteArray -> none:
    unreachable  // Here to satisfy the checker.

  channel_receive_page handle/int --peek/int --buffer/ByteArray? -> ByteArray:
    unreachable  // Here to satisfy the checker.

  channel_acknowledge handle/int sn/int count/int -> none:
    unreachable  // Here to satisfy the checker.

  channel_open client/int --topic/string --receive/bool -> ChannelResource:
    return ChannelResource this client --topic=topic --receive=receive

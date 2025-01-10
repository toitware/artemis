// Copyright (C) 2023 Toitware ApS. All rights reserved.

import system.services show ServiceHandler ServiceResource ServiceProvider
import system.storage

import .flashlog show FlashLog SN
import artemis-pkg.api

flashlogs_ ::= {:}
receivers_ ::= {}

class ChannelResource extends ServiceResource:
  topic/string
  receive/bool
  log_/FlashLog? := ?

  constructor provider/ServiceProvider client/int --.topic --.receive --capacity/int?:
    if receive and receivers_.contains topic: throw "ALREADY_IN_USE"
    log_ = flashlogs_.get topic --init=:
      path := "toit.io/channel/$topic"
      FlashLog (storage.Region.open --flash path --capacity=capacity)
    if receive: receivers_.add topic
    log_.acquire
    super provider client

  capacity -> int:
    return log_.capacity

  size -> int:
    return log_.size

  send bytes/ByteArray -> bool:
    log_.append bytes --if-full=: return false
    return true

  receive-page --peek/int --buffer/ByteArray? -> List:
    if not receive: throw "PERMISSION_DENIED"
    buffer = buffer or (ByteArray log_.capacity-per-page_)
    return log_.read-page buffer --peek=peek

  acknowledge sn/int count/int -> none:
    if not receive: throw "PERMISSION_DENIED"
    if count < 1: throw "Bad Argument"
    log_.acknowledge (SN.previous (SN.next sn --increment=count))

  on-closed -> none:
    log := log_
    if not log: return
    log_ = null
    if receive: receivers_.remove topic
    if log.release == 0: flashlogs_.remove topic

class ChannelServiceProvider extends ServiceProvider
    implements ServiceHandler:
  constructor name/string --major/int --minor/int:
    super name --major=major --minor=minor

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ArtemisService.CHANNEL-SEND-INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.send arguments[1]
    if index == api.ArtemisService.CHANNEL-RECEIVE-PAGE-INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.receive-page --peek=arguments[1] --buffer=arguments[2]
    if index == api.ArtemisService.CHANNEL-ACKNOWLEDGE-INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.acknowledge arguments[1] arguments[2]
    if index == api.ArtemisService.CHANNEL-OPEN-INDEX:
      // The CHANNEL-OPEN-INDEX method exists in two variants. The
      // old one is deprecated and doesn't provide the capacity in
      // the arguments list. We can remove the old variant when we
      // introduce other breaking changes since newer client code
      // does not use it.
      capacity := arguments.size >= 3 ? arguments[2] : 32 * 1024
      return channel-open client
           --topic=arguments[0]
           --receive=arguments[1]
           --capacity=capacity
    if index == api.ArtemisService.CHANNEL-SIZE-INDEX:
      channel := (resource client arguments) as ChannelResource
      return channel.size
    if index == api.ArtemisService.CHANNEL-CAPACITY-INDEX:
      channel := (resource client arguments) as ChannelResource
      return channel.capacity
    unreachable

  channel-open --topic/string --receive/bool -> int?:
    unreachable  // Here to satisfy the checker.

  channel-open --topic/string --receive/bool --capacity/int? -> int?:
    unreachable  // Here to satisfy the checker.

  channel-send handle/int bytes/ByteArray -> bool:
    unreachable  // Here to satisfy the checker.

  channel-receive-page handle/int --peek/int --buffer/ByteArray? -> ByteArray:
    unreachable  // Here to satisfy the checker.

  channel-acknowledge handle/int sn/int count/int -> none:
    unreachable  // Here to satisfy the checker.

  channel-capacity handle/int -> int:
    unreachable  // Here to satisfy the checker.

  channel-size handle/int -> int:
    unreachable  // Here to satisfy the checker.

  channel-open client/int --topic/string --receive/bool --capacity/int? -> ChannelResource:
    return ChannelResource this client --topic=topic --receive=receive --capacity=capacity

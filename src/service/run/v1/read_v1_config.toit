import .magic
import .proto.api.config_pb as proto
import protobuf
import .tpack as tpack

main:
  config_bytes := TOIT_CONFIG
  16.repeat: print "0x$(%02x config_bytes[it])"
  decoded := tpack.Message.in config_bytes
  deserialized := proto.Config.deserialize decoded
  print deserialized.is_empty
  print deserialized.name
  deserialized.connection.connections.do: | connection/proto.Connection |
    print "ssid: $connection.network_wifi.ssid"
    print "password: $connection.network_wifi.password"

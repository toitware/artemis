import net
import encoding.json
import host.pipe

get_external_ip -> string:
  if platform != PLATFORM_LINUX:
    print "Only linux is supported"
    exit 1

  // Get the external IP.
  route_out := pipe.backticks "ip" "-j" "route" "get" "1"
  decoded := json.parse route_out
  external_ip := decoded[0]["prefsrc"]
  if not external_ip:
    throw "Could not get external IP"
  return external_ip

main:
  print get_external_ip

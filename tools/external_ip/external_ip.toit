import net
import encoding.json
import host.pipe

main:
  print external_ip

external_ip -> string:
  if platform == PLATFORM_LINUX:
    return external_ip_linux
  else if platform == PLATFORM_MACOS:
    return external_ip_macos
  print "Platform '$platform' is not supported."
  exit 1
  unreachable

external_ip_linux -> string:
  // Get the external IP.
  route_out := pipe.backticks "ip" "-j" "route" "get" "1"
  decoded := json.parse route_out
  ip := decoded[0]["prefsrc"]
  if not ip:
    print "Could not get external IP."
    exit 1
  return ip

external_ip_macos -> string:
  // Get the external IP using DNS through dig as described here:
  // https://apple.stackexchange.com/questions/20547/how-do-i-find-my-ip-address-from-the-command-line
  dig_out := pipe.backticks [
    "dig", "-4", "TXT", "+short",
    "o-o.myaddr.l.google.com",
    "@ns1.google.com"
  ]
  decoded := json.parse dig_out
  ip := decoded  // We only get one string back.
  if not ip:
    print "Could not get external IP."
    exit 1
  return ip

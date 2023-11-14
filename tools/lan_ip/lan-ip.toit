import net
import encoding.json
import host.pipe
import system

main:
  print get-lan-ip

get-lan-ip -> string:
  if system.platform == system.PLATFORM-LINUX:
    return get-lan-ip-linux
  else if system.platform == system.PLATFORM-MACOS:
    return get-lan-ip-macos
  print "Platform '$system.platform' is not supported."
  exit 1
  unreachable

get-lan-ip-linux -> string:
  // Get the LAN IP.
  route-out := pipe.backticks "ip" "-j" "route" "get" "1"
  decoded := json.parse route-out
  lan-ip := decoded[0]["prefsrc"]
  if not lan-ip:
    print "Could not get LAN IP."
    exit 1
  return lan-ip

get-lan-ip-macos -> string:
  // First find the default interface name using route.
  route-out := pipe.backticks "route" "-n" "get" "default"
  interface-name := ""
  (route-out.split "\n").do: | line/string |
    line = line.trim
    if line.starts-with "interface":
      colon-index := line.index-of ":"
      if colon-index >= 0:
        interface-name = line[colon-index + 1 ..].trim
  // Then use ipconfig get the address.
  ipconfig-out := pipe.backticks "ipconfig" "getifaddr" interface-name
  lan-ip := ipconfig-out.trim
  return lan-ip

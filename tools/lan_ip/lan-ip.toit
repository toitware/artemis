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
  else if system.platform == system.PLATFORM-WINDOWS:
    return get-lan-ip-windows
  else:
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

get-lan-ip-windows -> string:
  /*
  Sample output from a GitHub runner (where this function would return 10.1.0.85):

    Windows IP Configuration
    Ethernet adapter Ethernet:
      Connection-specific DNS Suffix  . : oukbeomqr2puhfunxs1jexdhoh.ex.internal.cloudapp.net
      Link-local IPv6 Address . . . . . : fe80::2f2e:417d:6f7e:2eb1%13
      IPv4 Address. . . . . . . . . . . : 10.1.0.85
      Subnet Mask . . . . . . . . . . . : 255.255.0.0
      Default Gateway . . . . . . . . . : 10.1.0.1
    Ethernet adapter vEthernet (nat):
      Connection-specific DNS Suffix  . :
      Link-local IPv6 Address . . . . . : fe80::56ac:c952:af1a:19f9%9
      IPv4 Address. . . . . . . . . . . : 192.168.192.1
      Subnet Mask . . . . . . . . . . . : 255.255.240.0
      Default Gateway . . . . . . . . . :
  */
  output := pipe.backticks "ipconfig"
  lines := output.split "\n"
  lines.do: | line |
    if line.contains "IPv4 Address":
      parts := line.split ":"
      ip := parts[1].trim
      if ip.contains "(":
        ip = (ip.split " ")[0]
      return ip
  throw "Could not get LAN IP."

# Artemis

Artemis consists of two parts:  A service that runs on the devices, and a CLI
that allows you to control the devices.

They communicate together using an MQTT service in the cloud.  Currently that
is AWS's IOT service.  The device group has a name, currently hard coded in
`shared/connect.toit` to be `fisk`.  CLI commands can change settings of all
devices in the named group.

To build, start in toitlang/toit and use

```shell
make flash ESP32_ENTRY=$HOME/Toitware/artemis/src/service/main.toit ESP32_PORT=/dev/ttyUSB0 ESP32_WIFI_SSID=mywifi ESP32_WIFI_PASSWORD=mypassword
```

(Currently you need to first zap the flash with 
`./third_party/esp-idf/components/esptool_py/esptool/esptool.py erase_flash`).

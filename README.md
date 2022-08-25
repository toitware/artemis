# Artemis

Artemis consists of two parts:  A service that runs on the devices, and a CLI
that allows you to control the devices.

They communicate together using an MQTT service in the cloud.  Currently that
is AWS's IoT service.  On the ESP32, the device uses the Jaguar device name a uuid 
generated from its MAC address as its name.  On host platforms, we currently
just use the hostname.

CLI commands can change settings of the device. Things like max-offline or the set
of installed applications.

To build, start in toitlang/toit and use:

``` sh
make flash ESP32_ENTRY=$HOME/Toitware/artemis/src/service/main.toit ESP32_PORT=/dev/ttyUSB0 ESP32_WIFI_SSID=mywifi ESP32_WIFI_PASSWORD=mypassword
```

(Currently you need to first zap the flash with 
`./third_party/esp-idf/components/esptool_py/esptool/esptool.py erase_flash`).

Also runs under Jaguar as an installable app.

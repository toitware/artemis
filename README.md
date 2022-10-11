# Artemis

Artemis consists of two parts:  A service that runs on the devices, and a CLI
that allows you to control the devices.

They communicate together using MQTT or HTTP via a cloud service.  Currently the
cloud service is AWS's IoT service or a Supabase instance.  On the ESP32, the 
device keeps track of its device id after the initial flashing. 

CLI commands can change settings of the device.  Things like max-offline or the setgit
of installed applications.

To put Artemis on a device, you first put together the firmware you want to
run on the device. Let's put it in `firmware.envelope` using:

``` sh
toit.run src/cli/cli.toit firmware create -o firmware.envelope
```

Then you create a device identity for the device you're provisioning:

``` sh
toit.run src/cli/cli.toit provision create-identity
```

That gives you a `<xxx>.identity` file that can be used to do the initial flashing
of a device.

``` sh
toit.run src/cli/cli.toit firmware flash \
    --identity=<xxx>.identity \
    --wifi-ssid=mywifi --wifi-password=mypassword \
    firmware.envelope
```

For now, this actually doesn't flash the device, but it will generate a device-specific
envelope that you can flash using 'jag flash':

``` sh
jag flash --exclude-jaguar <xxx>.envelope
```

Happy hacking!

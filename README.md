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

If you want to test this out, you can pass `--simulate` to the `firmware flash` command
and this will do on-host simulation of running the firmware on an ESP32.

You can now change the Artemis code a bit (or the SDK pointed to through `JAG_TOIT_REPO_PATH`) and 
create new firmware:

``` sh
toit.run src/cli/cli.toit firmware create -o new.envelope
```

and tell your device to update to it:

``` sh
toit.run src/cli/cli.toit firmware update -d <xxx> new.envelope
```

Happy hacking!

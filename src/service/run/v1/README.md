# V1-to-v2 migration guide

Devices must first grow their partitions. There are v1.6 builds that do this
automatically. Note that the partition-growing firmware deletes any
custom configuration, also from the roll-back partition. It is crucial that
the device has its configuration as part of a firmware update.

Once the the partition is big enough, an Artemis image can be flashed onto
the device.

## Config migration

Any artemis image build with this branch will automatically receive the
hardware ID and the WiFi connections from the original configuration.

Typically, cellular connections are uniform across a fleet, and we
can generate custom firmwares for our customers for these configurations.
The customer just needs to give us a pod-specification that works for them.

## Creation of v1 images

- Create a pod image. Write it as a file, as we want to use it as a
  diff-base for future updates to the device.
- Use `serial write_ota` to write the ota image. This will create
  a new device ID, which we can safely ignore. This step must be
  done agains the official server (and not a local http server), as
  the connection information is stored in the pod.

As of 2023-08-02 untested:

- create a new v1.6 build artifact (just pushing to branch release-v1.6 should
  be enough)
- go to https://console.cloud.google.com/storage/browser/toit-binaries and
  find your build. For example,
  https://console.cloud.google.com/storage/browser/toit-binaries/v1.6.26-pre.9+832de3bf5
- In the sdk folder download the tar archive
- Inside the tar file replace the 'factory.bin' with the Artemis OTA image.
- Upload the tar file back to the same location in the bucket.

# Artemis - v1_migration branch.

This branch is for migrating Toit v1 devices to Artemis.

## How to create new Artemis service images

Check out this branch (`v1_migration`), then run the following
command to upload the current checkout to the v1_migration organization:

```
make
build/bin/uploader service --local \
    --sdk-version=v2.0.0-alpha.94
    --service-version=v0.9.2-migration2
    --organization-id 367459ff-7ad2-4b3f-8085-4a5dcc2cd82f
```
Replace the versions as needed.

## How to create new v1 firmware images

Put yourself into a fleet with organization 367459ff-7ad2-4b3f-8085-4a5dcc2cd82f (`v1_migration``).

This org has v0.9.2-migrationX entries.

Run `artemis sdk list` to find the latest entry.

Change the pod-spec so it uses that combo and change the connection settings
so that the devices can connect to the server. WiFi is inherited from v1, but
cellular connections must be added to the pod spec.

```
artemis pod build -o migration.pod my-pod.json
```

Use the same pod file to create an ota image:
```
artemis serial write-ota -o ota.bin --local migration.pod
```
Note: this will create a new ID that we will ignore.

Create a meaningful tag on the release-v1.99 branch:
```
git checkout release-v1.99
git tag v1.99.0-customer-foo
git push origin v1.99.0-customer-foo
```

This will automatically trigger a Github action that will upload the
new image. The `gitversion` script will detect the tag and use it
as version for this build.

Once the Action has finished get the tar (`sdk/v1.99.0-customer-foo.tar``) from google storage
https://console.cloud.google.com/storage/browser/toit-binaries/v1.99.0-customer-foo
(You can also use command-line tools for this, but through the browser is probably easier).

Untar it, and replace model/esp32-4mb/factory.bin with the ota.bin that was created with Artemis.
Remove the downloaded tar (if it's in the same directory) and create a new tar:
```
tar c -f v1.99.0-customer-foo.tar ./*
```

Upload this file to google storage, overwriting the original one. (google storage should
ask for confirmation).

Now we need to make the new image available on the Toit console. For this, log into
the debug pod (replace the pod name with the one from `get pods`).

```
kubectl get pods
kubectl exec -it debug-5776c8657f-2brm5 -- bash
```

Then run the following commands in the pod
```
update_sdk.sh v1.99.0-customer-foo
```

The image is now available on the console.

## How to migrate a device

In the Artemis fleet where the device should live:
```
artemis fleet create-identity <HW-ID>
```
It's important to use the hardware ID of the device (as reported on the Toit console).

It makes sense to call `artemis fleet roll-out` at this point so that the device
can download the new image as soon as it goes online.

Then, update the device (in the Toit v1 console) to two v1.7 images. It's
crucial that the log reports "booting from partition at offset 1b0000".
This means that the partition table has been successfully changed and can now
accomodate the larger Artemis images.

Then, update the device to the Artemis image that was built for the device.
For devices that only need WiFi the latest `v1.99.x-wifi` should be enough.

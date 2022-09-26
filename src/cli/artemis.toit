// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.sha256
import host.file
import uuid

import .sdk
import ..shared.mediator

/**
Manages devices that have an Artemis service running on them.
*/
class Artemis:
  mediator_/MediatorCli

  constructor .mediator_:

  close:
    // Do nothing for now.
    // The mediators are not created here and should be closed outside.

  /**
  Maps a device name to its id.
  */
  device_name_to_id name/string -> string:
    return name

  app_install --device_id/string --app_name/string --application_path/string:
    images := application_to_images application_path
    id := images.id
    mediator_.upload_image --app_id=id --bits=32 images.image32
    mediator_.upload_image --app_id=id --bits=64 images.image64

    mediator_.device_update_config --device_id=device_id: | config/Map |
      print "$(%08d Time.monotonic_us): Installing app: $app_name"
      apps := config.get "apps" --if_absent=: {:}
      apps[app_name] = {"id": id, "random": (random 1000)}
      config["apps"] = apps
      config

  app_uninstall --device_id/string --app_name/string:
    mediator_.device_update_config --device_id=device_id: | config/Map |
      print "$(%08d Time.monotonic_us): Uninstalling app: $app_name"
      apps := config.get "apps"
      if apps: apps.remove app_name
      config

  config_set_max_offline --device_id/string --max_offline_seconds/int:
    mediator_.device_update_config --device_id=device_id: | config/Map |
      print "$(%08d Time.monotonic_us): Setting max-offline to $(Duration --s=max_offline_seconds)"
      if max_offline_seconds > 0:
        config["max-offline"] = max_offline_seconds
      else:
        config.remove "max-offline"
      config

  firmware_update --device_id/string --firmware_path/string:
    firmware_bin := file.read_content firmware_path
    sha := sha256.Sha256
    sha.add firmware_bin
    id/string := "$(uuid.Uuid sha.get[0..uuid.SIZE])"

    mediator_.upload_firmware --firmware_id=id firmware_bin

    mediator_.device_update_config --device_id=device_id: | config/Map |
      config["firmware"] = id
      config


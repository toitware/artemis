// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import system.assets

import ..monitoring show ping_setup ping_device_assets
import ..service show run_artemis

main arguments:
  decoded ::= assets.decode
  broker := ping_device_assets "broker" decoded
  device := ping_setup decoded
  run_artemis device broker

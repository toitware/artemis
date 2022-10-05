// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import system.assets

import ..broker show decode_broker
import ..status show report_status_setup
import ..service show run_artemis

main arguments:
  decoded ::= assets.decode
  broker := decode_broker "broker" decoded
  device := report_status_setup decoded
  run_artemis device broker

// Copyright (C) 2022 Toitware ApS. All rights reserved.

import system.assets
import ..monitoring show ping_setup
import ..service show run_artemis

main arguments:
  device := ping_setup assets.decode
  run_artemis device {:}

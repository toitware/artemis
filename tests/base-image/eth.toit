// Copyright (C) 2023 Toitware ApS.

import esp32.net.ethernet as esp32
import system.containers

class OpenEthProvider extends esp32.EthernetServiceProvider:
  is-open_/bool := false

  constructor:
    super.mac-openeth --phy-chip=esp32.PHY-CHIP-DP83848

  on-module-opened module:
    is-open_ = true
    containers.notify-background-state-changed false
    super module

  on-module-closed module:
    super module
    is-open_ = false
    containers.notify-background-state-changed true

  mark-background_:
    if not is-open_:
      containers.notify-background-state-changed true

main:
  provider := OpenEthProvider
  provider.install
  provider.mark-background_

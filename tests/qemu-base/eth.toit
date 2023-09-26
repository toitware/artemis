// Copyright (C) 2023 Toitware ApS.

import esp32.net.ethernet as esp32
import system.containers

class OpenEthProvider extends esp32.EthernetServiceProvider:
  constructor:
    super.mac-openeth --phy-chip=esp32.PHY-CHIP-DP83848

  on-module-opened module:
    containers.notify-background-state-changed false
    super module

  on-module-closed module:
    super module
    containers.notify-background-state-changed true

main:
  containers.notify-background-state-changed true
  provider := esp32.EthernetServiceProvider.mac-openeth
      --phy-chip=esp32.PHY-CHIP-DP83848
  provider.install

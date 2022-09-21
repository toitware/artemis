// Copyright (C) 2022 Toitware ApS. All rights reserved.

interface ResourceManager:
  fetch_image id/string [block] -> none
  fetch_firmware id/string [block] -> none
  fetch_resource path/string [block] -> none

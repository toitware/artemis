// Copyright (C) 2022 Toitware ApS. All rights reserved.

interface ResourceManager:
  fetch_resource path/string [block] -> none
  fetch_resource path/string size/int offsets/List [block] -> none

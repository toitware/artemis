// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .ui

interface Authenticatable:
  /**
  Ensures that the user is authenticated.

  If the user is not authenticated, the $block is called with an
    error string.
  */
  ensure_authenticated [block]

  /**
  Signs the user up with the given $email and $password.
  */
  sign_up --email/string --password/string

  /**
  Signs the user in with the given $email and $password.
  */
  sign_in --email/string --password/string

  /**
  Signs the user in using OAuth.
  */
  sign_in --provider/string --ui/Ui --open_browser/bool

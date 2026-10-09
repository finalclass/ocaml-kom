let local_system expected supplied =
  if expected<>supplied then Message_codec.fail "System" "A receipt belongs to another system"

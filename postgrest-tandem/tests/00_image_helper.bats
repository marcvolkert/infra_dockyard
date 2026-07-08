#!/usr/bin/env bats

load ./test_helper.bash

@test "gosu helper drops privileges to postgres" {
  run ctr run --rm --entrypoint /usr/local/bin/gosu "$TEST_IMAGE" postgres bash -c 'printf "%s|%s" "$(id -un)" "$(id -gn)"'
  [ "$status" -eq 0 ]
  [ "$output" = "postgres|postgres" ]
}

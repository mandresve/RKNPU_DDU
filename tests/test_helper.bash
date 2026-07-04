# Load update.sh without running main, so pure functions can be tested.
load_update() {
  export RKNPU_SOURCE_ONLY=1
  # shellcheck disable=SC1091
  source "${BATS_TEST_DIRNAME}/../update.sh"
}
# shellcheck disable=SC2034  # used from the .bats files that 'load' this helper
FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

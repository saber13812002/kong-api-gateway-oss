#!/usr/bin/env bash
# Kong OSS release — run the FULL mandatory test suite (18 tests) +
# the 9 security boundary cases, against the loopback proxy.
#
# Exit code 0 only if every test passes.
source "$(dirname "$0")/_common.sh"

require_cmd python3

log "=== full test suite (18 mandatory + 9 boundary) ==="
python3 "$ROOT_DIR/tests/test_suite.py" "$PROXY_URL" "$ADMIN_URL" "$ECHO_BACKEND_NAME"
SUITE_RC=$?

log "=== security boundary tests (9 cases) ==="
python3 "$ROOT_DIR/tests/boundary.py" "$PROXY_URL" "$ECHO_BACKEND_NAME"
BOUNDARY_RC=$?

echo
if [ "$SUITE_RC" -eq 0 ] && [ "$BOUNDARY_RC" -eq 0 ]; then
  log "ALL TESTS PASSED"
  exit 0
else
  log "TEST FAILURES: suite_rc=$SUITE_RC boundary_rc=$BOUNDARY_RC"
  exit 1
fi

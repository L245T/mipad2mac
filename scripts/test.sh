#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
# CLT 27 beta's Swift Build does not discover TestingMacros automatically.
SWIFT_BIN="$(xcrun --find swiftc)"
TEST_PLUGIN="$(dirname "$SWIFT_BIN")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TEST_PLUGIN" ]]; then
    swift test --disable-sandbox --cache-path .build/cache -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN"
else
    swift test --disable-sandbox --cache-path .build/cache
fi

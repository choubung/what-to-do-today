#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/what-to-do-today-check.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

xcrun swiftc -swift-version 6 -module-cache-path "$build_dir/modules" \
  Shared/TodoItem.swift Shared/TodoStore.swift Tests/TaskStoreTests.swift \
  -o "$build_dir/store-tests"
"$build_dir/store-tests"

xcrun swiftc -typecheck -swift-version 6 \
  -target "$(uname -m)-apple-macos27.0.1" \
  -module-cache-path "$build_dir/modules" Shared/*.swift App/*.swift
plutil -lint App/Info.plist App/App.entitlements WhatToDoToday.xcodeproj/project.pbxproj

xcrun swiftc -typecheck -application-extension -swift-version 6 \
  -target "$(uname -m)-apple-macos27.0.1" \
  -module-cache-path "$build_dir/modules" Shared/*.swift Widget/*.swift
plutil -lint Widget/Info.plist Widget/Widget.entitlements

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs LanternCore's unit tests (swift test); extra arguments go to swift test (--filter ...).
set -euo pipefail
cd -- "$(dirname -- "$0")"
# SwiftPM's Bundle.module crashes the released app on older toolchains; use Bundle.resources
# (Sources/*/ResourceBundle.swift).
if grep -rnE --exclude=ResourceBundle.swift '(Bundle)?\.module\b' Sources Tests; then
    echo "Use Bundle.resources, not Bundle.module (see Sources/LanternCore/ResourceBundle.swift)." >&2
    exit 1
fi
swift test "$@"

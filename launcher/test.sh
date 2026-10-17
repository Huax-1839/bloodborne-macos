#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs LanternCore's unit tests (swift test); extra arguments go to swift test (--filter ...).
set -euo pipefail
cd -- "$(dirname -- "$0")"
swift test "$@"

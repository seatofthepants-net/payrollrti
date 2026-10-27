#!/bin/sh
# Formats Swift sources in place and lints them, matching what CI checks.
set -eu
cd "$(dirname "$0")/.."
swift format format --in-place --recursive PayrollRTI PayrollRTITests
swiftlint lint --strict

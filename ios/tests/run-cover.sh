#!/bin/sh
set -eu
taskRoot=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
taskOutput="$taskRoot/.cover-tests"
mkdir -p "$taskOutput"
swiftc "$taskRoot/MotoNav/CoverEncoder.swift" "$taskRoot/tests/cover/main.swift" -o "$taskOutput/cover"
"$taskOutput/cover"

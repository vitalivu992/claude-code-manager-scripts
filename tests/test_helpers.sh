#!/bin/bash
PASS=0
FAIL=0
TEST_COUNT=0
CURRENT_TEST=""

setup_test_env() {
    TEST_HOME=$(mktemp -d)
    export HOME="$TEST_HOME"
    mkdir -p "$TEST_HOME/.claude-auto-code"
    TEST_REPO=$(mktemp -d)
}

teardown_test_env() {
    rm -rf "$TEST_HOME" "$TEST_REPO" 2>/dev/null
}

describe() {
    echo ""
    echo "=== $1 ==="
}

it() {
    CURRENT_TEST="$1"
    TEST_COUNT=$((TEST_COUNT + 1))
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-$CURRENT_TEST}"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  ✅ $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ $msg"
        echo "     expected: '$expected'"
        echo "     actual:   '$actual'"
    fi
}

assert_empty() {
    local actual="$1"
    local msg="${2:-$CURRENT_TEST}"
    if [ -z "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  ✅ $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ $msg"
        echo "     expected empty, got: '$actual'"
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="${2:-$CURRENT_TEST}"
    if [ -f "$path" ]; then
        PASS=$((PASS + 1))
        echo "  ✅ $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ $msg"
        echo "     file not found: $path"
    fi
}

assert_file_not_exists() {
    local path="$1"
    local msg="${2:-$CURRENT_TEST}"
    if [ ! -f "$path" ]; then
        PASS=$((PASS + 1))
        echo "  ✅ $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ $msg"
        echo "     file should not exist: $path"
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-$CURRENT_TEST}"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  ✅ $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ $msg"
        echo "     expected exit code: $expected, got: $actual"
    fi
}

print_summary() {
    echo ""
    echo "==============================="
    echo "Results: $PASS passed, $FAIL failed (out of $((PASS + FAIL)) assertions)"
    echo "==============================="
    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
}

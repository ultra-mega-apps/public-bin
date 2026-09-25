#!/usr/bin/env bash
#
# Unit tests for the DEPLOY parser and ref->environment mapping in
# github-actions-deploy-me.sh. Pure bash, no network, no dependencies.
#
# Usage: tests/test-parser.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../github-actions-deploy-me.sh"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
  fi
}

assert_fails_with() {
  local desc="$1" expected_msg="$2"
  shift 2
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (expected failure, got success)\n' "$desc" >&2
  elif [[ "$out" == *"$expected_msg"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected message containing: %s\n  actual: %s\n' "$desc" "$expected_msg" "$out" >&2
  fi
}

# --- happy path ---

assert_eq "STAGING lookup" \
  "https://a:50000" \
  "$(parse_deploy_var 'STAGING|https://a:50000|PRODUCTION|https://b:50000' STAGING)"

assert_eq "PRODUCTION lookup" \
  "https://b:50000" \
  "$(parse_deploy_var 'STAGING|https://a:50000|PRODUCTION|https://b:50000' PRODUCTION)"

assert_eq "spaces around fields are trimmed (STAGING)" \
  "https://a:50000" \
  "$(parse_deploy_var 'STAGING | https://a:50000 | PRODUCTION | https://b:50000' STAGING)"

assert_eq "spaces around fields are trimmed (PRODUCTION)" \
  "https://b:50000" \
  "$(parse_deploy_var 'STAGING | https://a:50000 | PRODUCTION | https://b:50000' PRODUCTION)"

# --- invalid input ---

assert_fails_with "missing DEPLOY" \
  "DEPLOY is empty or not set" \
  parse_deploy_var "" STAGING

assert_fails_with "blank DEPLOY" \
  "DEPLOY is empty or not set" \
  parse_deploy_var "   " STAGING

assert_fails_with "odd number of fields" \
  "odd number" \
  parse_deploy_var "STAGING|https://a:50000|PRODUCTION" STAGING

assert_fails_with "environment without URL" \
  "has no URL" \
  parse_deploy_var "STAGING|https://a:50000|PRODUCTION|   |FOO|https://f:50000" PRODUCTION

assert_fails_with "empty environment name" \
  "empty environment name" \
  parse_deploy_var "STAGING|https://a:50000||https://b:50000" STAGING

assert_fails_with "empty URL" \
  "has no URL" \
  parse_deploy_var "STAGING| " STAGING

assert_fails_with "duplicated environment" \
  "duplicated environment 'STAGING'" \
  parse_deploy_var "STAGING|https://a:50000|STAGING|https://b:50000" STAGING

assert_fails_with "STAGING missing" \
  "No endpoint configured for environment STAGING" \
  parse_deploy_var "PRODUCTION|https://b:50000" STAGING

assert_fails_with "PRODUCTION missing" \
  "No endpoint configured for environment PRODUCTION" \
  parse_deploy_var "STAGING|https://a:50000" PRODUCTION

# --- ref -> environment mapping ---

assert_eq "refs/heads/main -> STAGING" \
  "STAGING" \
  "$(environment_from_ref 'refs/heads/main')"

assert_eq "refs/tags/v1.2.3 -> PRODUCTION" \
  "PRODUCTION" \
  "$(environment_from_ref 'refs/tags/v1.2.3')"

assert_eq "refs/tags/* with slashes -> PRODUCTION" \
  "PRODUCTION" \
  "$(environment_from_ref 'refs/tags/release/2026.09')"

assert_fails_with "feature branch rejected" \
  "" \
  environment_from_ref "refs/heads/feature-x"

assert_fails_with "pull request ref rejected" \
  "" \
  environment_from_ref "refs/pull/1/merge"

assert_fails_with "bare refs/tags/ rejected" \
  "" \
  environment_from_ref "refs/tags/"

printf 'parser tests: %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))

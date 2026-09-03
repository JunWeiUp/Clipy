#!/usr/bin/env bash
# Shared, side-effect-free metadata for both platform build entrypoints.
# REPO_ROOT is supplied by the calling script; never guess a developer's SDK path.

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

validate_boolean() {
  case "$2" in
    0|1) ;;
    *) fail "$1 must be 0 or 1" ;;
  esac
}

resolve_build_version() {
  local package_version
  package_version="$(awk '/^version:/ {print $2; exit}' "${REPO_ROOT}/clipy_android/pubspec.yaml")"
  APP_VERSION="${APP_VERSION:-${package_version%%+*}}"
  BUILD_NUMBER="${BUILD_NUMBER:-${package_version##*+}}"
  [[ "${APP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "APP_VERSION must be X.Y.Z"
  [[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_NUMBER must be a positive integer"
  # Keep the Android versionCode within the platform's supported range.
  [ "${#BUILD_NUMBER}" -le 10 ] && [ "${BUILD_NUMBER}" -le 2100000000 ] || fail "BUILD_NUMBER is too large"
}

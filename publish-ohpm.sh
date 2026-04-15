#!/bin/bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${OHPM_REGISTRY:-https://ohpm.openharmony.cn/ohpm/}"
PRODUCT_NAME="${PRODUCT_NAME:-default}"
BUILD_TARGET="${BUILD_TARGET:-default}"
MODULE_TYPE="${1:-agent}"
OHPM_PUBLISH_ID_VALUE="${OHPM_PUBLISH_ID:-${PUBLISH_ID:-}}"
OHPM_KEY_PATH_VALUE="${OHPM_KEY_PATH:-${KEY_PATH:-}}"
OHPM_KEY_PASSPHRASE_VALUE="${OHPM_KEY_PASSPHRASE:-${KEY_PASSPHRASE:-}}"

if [[ "$MODULE_TYPE" != "agent" && "$MODULE_TYPE" != "ft_sdk_ext" && "$MODULE_TYPE" != "native" && "$MODULE_TYPE" != "all" ]]; then
  echo "Usage: $0 [agent|ft_sdk_ext|native|all]"
  echo "  agent: build and publish ft_sdk + ft_sdk_ext"
  echo "  ft_sdk_ext: build and publish ft_sdk_ext only"
  echo "  native: build and publish ft_native"
  echo "  all: build and publish ft_sdk + ft_sdk_ext + ft_native"
  exit 1
fi

if command -v ohpm >/dev/null 2>&1; then
  OHPM_BIN="$(command -v ohpm)"
else
  echo "Error: ohpm command not found in PATH"
  exit 1
fi

if [[ -n "${HARMONY_OS_NODE_PATH:-}" ]]; then
  NODE_BIN="$HARMONY_OS_NODE_PATH"
elif command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
else
  echo "Error: node command not found. Set HARMONY_OS_NODE_PATH or add node to PATH"
  exit 1
fi

if [[ -n "${HARMONY_OS_HVIGOR_PATH:-}" ]]; then
  HVIGOR_JS="$HARMONY_OS_HVIGOR_PATH"
elif [[ -f "/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js" ]]; then
  HVIGOR_JS="/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js"
else
  echo "Error: hvigorw.js not found. Set HARMONY_OS_HVIGOR_PATH explicitly"
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/publish-ohpm.XXXXXX")"
PREVIOUS_REGISTRY=""
PREVIOUS_KEY_PASSPHRASE=""
RESTORE_KEY_PASSPHRASE=0
cleanup() {
  if [[ -n "$PREVIOUS_REGISTRY" ]]; then
    "$OHPM_BIN" config set registry "$PREVIOUS_REGISTRY" >/dev/null 2>&1 || true
  fi
  if [[ "$RESTORE_KEY_PASSPHRASE" -eq 1 ]]; then
    if [[ -n "$PREVIOUS_KEY_PASSPHRASE" ]]; then
      "$OHPM_BIN" config set key_passphrase "$PREVIOUS_KEY_PASSPHRASE" >/dev/null 2>&1 || true
    else
      "$OHPM_BIN" config delete key_passphrase >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

read_version() {
  local package_json_path="$1"
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$package_json_path" | head -n 1
}

ensure_publish_id() {
  if [[ -n "$OHPM_PUBLISH_ID_VALUE" ]]; then
    echo "Setting ohpm publish_id from environment variable"
    "$OHPM_BIN" config set publish_id "$OHPM_PUBLISH_ID_VALUE" >/dev/null
    return
  fi

  if ! "$OHPM_BIN" config get publish_id >/dev/null 2>&1; then
    echo "Error: ohpm publish_id is empty."
    echo "Set it with one of the following:"
    echo "  export OHPM_PUBLISH_ID=<your_publish_id>"
    echo "  export PUBLISH_ID=<your_publish_id>"
    echo "  ohpm config set publish_id <your_publish_id>"
    exit 1
  fi

  local publish_id
  publish_id="$("$OHPM_BIN" config get publish_id 2>/dev/null | tail -n 1 | tr -d '\r')"
  if [[ -z "$publish_id" || "$publish_id" == "undefined" || "$publish_id" == "null" ]]; then
    echo "Error: ohpm publish_id is empty."
    echo "Set it with one of the following:"
    echo "  export OHPM_PUBLISH_ID=<your_publish_id>"
    echo "  export PUBLISH_ID=<your_publish_id>"
    echo "  ohpm config set publish_id <your_publish_id>"
    exit 1
  fi
}

ensure_key_path() {
  if [[ -n "$OHPM_KEY_PATH_VALUE" ]]; then
    if [[ ! -f "$OHPM_KEY_PATH_VALUE" ]]; then
      echo "Error: OHPM_KEY_PATH file not found: $OHPM_KEY_PATH_VALUE"
      exit 1
    fi

    echo "Setting ohpm key_path from environment variable"
    "$OHPM_BIN" config set key_path "$OHPM_KEY_PATH_VALUE" >/dev/null
    return
  fi

  if ! "$OHPM_BIN" config get key_path >/dev/null 2>&1; then
    echo "Error: ohpm key_path is empty."
    echo "Set it with one of the following:"
    echo "  export OHPM_KEY_PATH=/path/to/private_key"
    echo "  export KEY_PATH=/path/to/private_key"
    echo "  ohpm config set key_path /path/to/private_key"
    exit 1
  fi

  local key_path
  key_path="$("$OHPM_BIN" config get key_path 2>/dev/null | tail -n 1 | tr -d '\r')"
  if [[ -z "$key_path" || "$key_path" == "undefined" || "$key_path" == "null" ]]; then
    echo "Error: ohpm key_path is empty."
    echo "Set it with one of the following:"
    echo "  export OHPM_KEY_PATH=/path/to/private_key"
    echo "  export KEY_PATH=/path/to/private_key"
    echo "  ohpm config set key_path /path/to/private_key"
    exit 1
  fi

  if [[ ! -f "$key_path" ]]; then
    echo "Error: configured key_path file not found: $key_path"
    exit 1
  fi
}

ensure_key_passphrase() {
  if [[ -z "$OHPM_KEY_PASSPHRASE_VALUE" ]]; then
    return
  fi

  PREVIOUS_KEY_PASSPHRASE="$("$OHPM_BIN" config get key_passphrase 2>/dev/null | tail -n 1 | tr -d '\r')"
  RESTORE_KEY_PASSPHRASE=1

  echo "Setting ohpm key_passphrase from environment variable"
  "$OHPM_BIN" config set key_passphrase "$OHPM_KEY_PASSPHRASE_VALUE" >/dev/null
}

set_registry() {
  if "$OHPM_BIN" config get registry >/dev/null 2>&1; then
    PREVIOUS_REGISTRY="$("$OHPM_BIN" config get registry 2>/dev/null | tail -n 1 | tr -d '\r')"
  fi

  echo "Setting ohpm registry to: $REGISTRY"
  "$OHPM_BIN" config set registry "$REGISTRY"
}

build_har() {
  local module_name="$1"
  local build_module="${module_name}@${BUILD_TARGET}"

  echo "Building HAR for ${module_name}..."
  (
    cd "$ROOT_DIR"
    "$NODE_BIN" "$HVIGOR_JS" --mode module -p product="$PRODUCT_NAME" -p module="$build_module" clean --analyze=normal
    "$NODE_BIN" "$HVIGOR_JS" --mode module -p product="$PRODUCT_NAME" -p module="$build_module" assembleHar --analyze=normal --parallel
  )
}

rewrite_har_dependency_for_ohpm() {
  local source_har="$1"
  local dependency_name="$2"
  local dependency_version="$3"
  local output_har="$4"
  local unpack_dir="$WORK_DIR/unpacked"
  local package_dir="$unpack_dir/package"

  rm -rf "$unpack_dir"
  mkdir -p "$unpack_dir"

  tar -xzf "$source_har" -C "$unpack_dir"

  local package_json_path="$package_dir/oh-package.json5"
  if [[ ! -f "$package_json_path" ]]; then
    echo "Error: oh-package.json5 not found inside $source_har"
    exit 1
  fi

  if grep -q "\"${dependency_name}\"[[:space:]]*:[[:space:]]*\"${dependency_version}\"" "$package_json_path"; then
    echo "Dependency ${dependency_name} already points to version ${dependency_version}, skip rewrite"
  else
    perl -0pi -e "s/\"${dependency_name}\"\\s*:\\s*\"file:\\.\\/[^\\\"]+\"/\"${dependency_name}\": \"${dependency_version}\"/g" "$package_json_path"

    if ! grep -q "\"${dependency_name}\"[[:space:]]*:[[:space:]]*\"${dependency_version}\"" "$package_json_path"; then
      echo "Error: failed to rewrite ${dependency_name} dependency in $package_json_path"
      exit 1
    fi
  fi

  (
    cd "$unpack_dir"
    tar -czf "$output_har" package
  )
}

publish_har() {
  local har_path="$1"
  echo "Publishing $(basename "$har_path") to $REGISTRY"
  "$OHPM_BIN" publish "$har_path"
}

publish_module() {
  local module_name="$1"
  local built_har="$ROOT_DIR/${module_name}/build/${PRODUCT_NAME}/outputs/${BUILD_TARGET}/${module_name}.har"
  local staged_har="$WORK_DIR/${module_name}.har"

  build_har "$module_name"

  if [[ ! -f "$built_har" ]]; then
    echo "Error: built HAR not found at $built_har"
    exit 1
  fi

  cp -f "$built_har" "$staged_har"

  if [[ "$module_name" == "ft_sdk_ext" ]]; then
    local sdk_version
    sdk_version="$(read_version "$ROOT_DIR/ft_sdk/oh-package.json5")"
    if [[ -z "$sdk_version" ]]; then
      echo "Error: unable to read ft_sdk version"
      exit 1
    fi

    echo "Rewriting ft_sdk_ext dependency from local HAR to version ${sdk_version}"
    rewrite_har_dependency_for_ohpm "$staged_har" "@guancecloud/ft_sdk" "$sdk_version" "$WORK_DIR/${module_name}.publish.har"
    staged_har="$WORK_DIR/${module_name}.publish.har"
  fi

  publish_har "$staged_har"
}

main() {
  ensure_publish_id
  ensure_key_path
  ensure_key_passphrase
  set_registry

  case "$MODULE_TYPE" in
    agent)
      publish_module "ft_sdk"
      publish_module "ft_sdk_ext"
      ;;
    ft_sdk_ext)
      publish_module "ft_sdk_ext"
      ;;
    native)
      publish_module "ft_native"
      ;;
    all)
      publish_module "ft_sdk"
      publish_module "ft_sdk_ext"
      publish_module "ft_native"
      ;;
  esac

  echo "Publish completed successfully for ${MODULE_TYPE}"
}

main "$@"

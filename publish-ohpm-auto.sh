#!/bin/bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${OHPM_PUBLISH_ENV_FILE:-$ROOT_DIR/.ohpm-publish.env}"
TARGET="${OHPM_PUBLISH_TARGET:-gc-uniplugin}"
INIT_ENV=0
DRY_RUN=0

usage() {
  echo "Usage: $0 [--init-env] [--dry-run] [--env <env_file>] [agent|ft_sdk_ext|ft_session_replay|native|all|gc-uniplugin]"
  echo
  echo "Defaults:"
  echo "  env file: $ROOT_DIR/.ohpm-publish.env"
  echo "  target:   $TARGET"
  echo "  build mode: debug (override with BUILD_MODE=release)"
}

is_truthy() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "y" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init-env)
      INIT_ENV=1
      ;;
    --env)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Error: --env requires a file path"
        usage
        exit 1
      fi
      ENV_FILE="$1"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    agent|ft_sdk_ext|ft_session_replay|native|all|gc-uniplugin)
      TARGET="$1"
      ;;
    *)
      echo "Error: unsupported argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ "$ENV_FILE" != /* ]]; then
  ENV_FILE="$ROOT_DIR/$ENV_FILE"
fi

create_env_file() {
  if [[ -e "$ENV_FILE" ]]; then
    echo "Error: env file already exists: $ENV_FILE"
    exit 1
  fi

  local default_key_path="/Users/zhuyun/Desktop/guance/OHPM-key/key_lizhao"
  if [[ ! -f "$default_key_path" ]]; then
    default_key_path=""
  fi

  umask 077
  cat > "$ENV_FILE" <<EOF
# Local OHPM publish config. This file is ignored by git.

OHPM_PUBLISH_ID=""
OHPM_KEY_PATH="$default_key_path"
OHPM_KEY_PASSPHRASE=""
OHPM_REGISTRY="https://ohpm.openharmony.cn/ohpm/"
OHPM_USE_SSH_AGENT=1

# GCUniPlugin debug packages use a prerelease version, for example alpha01.
BUILD_MODE="debug"
OHPM_SOURCE_TYPE="open"
OHPM_TAG="alpha"

# Optional GCUniPlugin host directory override.
GC_UNIPLUGIN_PROJECT_DIR="$ROOT_DIR/../ft-sdk-uniapp-native-plugin/NativeHostExample-Harmony/GuanceNativeModuleHost"

# Optional tool overrides.
# OHPM_BIN="/absolute/path/to/ohpm"
# HARMONY_OS_NODE_PATH="/absolute/path/to/node"
# HARMONY_OS_HVIGOR_PATH="/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js"
EOF
  chmod 600 "$ENV_FILE"
  echo "Created env file: $ENV_FILE"
}

if [[ "$INIT_ENV" -eq 1 ]]; then
  create_env_file
  exit 0
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: env file not found: $ENV_FILE"
  echo "Create it with: $0 --init-env"
  exit 1
fi

PRESET_OHPM_PUBLISH_ID="${OHPM_PUBLISH_ID:-}"
PRESET_PUBLISH_ID="${PUBLISH_ID:-}"
PRESET_OHPM_KEY_PATH="${OHPM_KEY_PATH:-}"
PRESET_KEY_PATH="${KEY_PATH:-}"
PRESET_OHPM_KEY_PASSPHRASE="${OHPM_KEY_PASSPHRASE:-}"
PRESET_KEY_PASSPHRASE="${KEY_PASSPHRASE:-}"
PRESET_BUILD_MODE="${BUILD_MODE:-}"
PRESET_OHPM_SOURCE_TYPE="${OHPM_SOURCE_TYPE:-}"
PRESET_OHPM_TAG="${OHPM_TAG:-}"
PRESET_GC_UNIPLUGIN_PROJECT_DIR="${GC_UNIPLUGIN_PROJECT_DIR:-}"

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

if [[ -n "$PRESET_OHPM_PUBLISH_ID" ]]; then
  OHPM_PUBLISH_ID="$PRESET_OHPM_PUBLISH_ID"
elif [[ -n "$PRESET_PUBLISH_ID" ]]; then
  PUBLISH_ID="$PRESET_PUBLISH_ID"
fi

if [[ -n "$PRESET_OHPM_KEY_PATH" ]]; then
  OHPM_KEY_PATH="$PRESET_OHPM_KEY_PATH"
elif [[ -n "$PRESET_KEY_PATH" ]]; then
  KEY_PATH="$PRESET_KEY_PATH"
fi

if [[ -n "$PRESET_OHPM_KEY_PASSPHRASE" ]]; then
  OHPM_KEY_PASSPHRASE="$PRESET_OHPM_KEY_PASSPHRASE"
elif [[ -n "$PRESET_KEY_PASSPHRASE" ]]; then
  KEY_PASSPHRASE="$PRESET_KEY_PASSPHRASE"
fi

if [[ -n "$PRESET_BUILD_MODE" ]]; then
  BUILD_MODE="$PRESET_BUILD_MODE"
fi

if [[ -n "$PRESET_OHPM_SOURCE_TYPE" ]]; then
  OHPM_SOURCE_TYPE="$PRESET_OHPM_SOURCE_TYPE"
fi

if [[ -n "$PRESET_OHPM_TAG" ]]; then
  OHPM_TAG="$PRESET_OHPM_TAG"
fi

if [[ -n "$PRESET_GC_UNIPLUGIN_PROJECT_DIR" ]]; then
  GC_UNIPLUGIN_PROJECT_DIR="$PRESET_GC_UNIPLUGIN_PROJECT_DIR"
fi

PUBLISH_ID_VALUE="${OHPM_PUBLISH_ID:-${PUBLISH_ID:-}}"
KEY_PATH_VALUE="${OHPM_KEY_PATH:-${KEY_PATH:-}}"
KEY_PASSPHRASE_VALUE="${OHPM_KEY_PASSPHRASE:-${KEY_PASSPHRASE:-}}"

if [[ -z "$PUBLISH_ID_VALUE" ]]; then
  echo "Error: OHPM_PUBLISH_ID is empty. Set it in $ENV_FILE or export it before running."
  exit 1
fi

if [[ -z "$KEY_PATH_VALUE" ]]; then
  echo "Error: OHPM_KEY_PATH is empty. Set it in $ENV_FILE or export it before running."
  exit 1
fi

if [[ ! -f "$KEY_PATH_VALUE" ]]; then
  echo "Error: OHPM_KEY_PATH file not found: $KEY_PATH_VALUE"
  exit 1
fi

export OHPM_PUBLISH_ID="$PUBLISH_ID_VALUE"
export OHPM_KEY_PATH="$KEY_PATH_VALUE"
export OHPM_REGISTRY="${OHPM_REGISTRY:-https://ohpm.openharmony.cn/ohpm/}"
export OHPM_USE_SSH_AGENT="${OHPM_USE_SSH_AGENT:-1}"
export BUILD_MODE="${BUILD_MODE:-debug}"
export OHPM_SOURCE_TYPE="${OHPM_SOURCE_TYPE:-open}"
export OHPM_TAG="${OHPM_TAG:-alpha}"
export GC_UNIPLUGIN_PROJECT_DIR="${GC_UNIPLUGIN_PROJECT_DIR:-$ROOT_DIR/../ft-sdk-uniapp-native-plugin/NativeHostExample-Harmony/GuanceNativeModuleHost}"
export OHPM_DRY_RUN="$DRY_RUN"
if [[ -n "$KEY_PASSPHRASE_VALUE" ]]; then
  export OHPM_KEY_PASSPHRASE="$KEY_PASSPHRASE_VALUE"
fi

if [[ -z "$KEY_PASSPHRASE_VALUE" ]] && ! is_truthy "${OHPM_AUTO_ALLOW_PROMPT:-0}"; then
  if command -v ssh-keygen >/dev/null 2>&1; then
    if ! ssh-keygen -y -P "" -f "$KEY_PATH_VALUE" >/dev/null 2>&1; then
      echo "Error: private key cannot be read without a passphrase, but OHPM_KEY_PASSPHRASE is empty."
      echo "Set OHPM_KEY_PASSPHRASE in $ENV_FILE, or set OHPM_AUTO_ALLOW_PROMPT=1 to allow manual input."
      exit 1
    fi
  fi
fi

if [[ -n "$KEY_PASSPHRASE_VALUE" ]] && command -v ssh-keygen >/dev/null 2>&1; then
  if ! ssh-keygen -y -P "$KEY_PASSPHRASE_VALUE" -f "$KEY_PATH_VALUE" >/dev/null 2>&1; then
    echo "Error: OHPM_KEY_PASSPHRASE cannot unlock the configured private key:"
    echo "  $KEY_PATH_VALUE"
    echo "Check that OHPM_KEY_PATH points to the expected key and OHPM_KEY_PASSPHRASE is correct."
    exit 1
  fi
fi

echo "Using OHPM env file: $ENV_FILE"
echo "Publishing target: $TARGET"
echo "Build mode: $BUILD_MODE"
echo "GCUniPlugin project: $GC_UNIPLUGIN_PROJECT_DIR"
exec "$ROOT_DIR/publish-ohpm.sh" "$TARGET"

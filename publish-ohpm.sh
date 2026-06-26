#!/bin/bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${OHPM_REGISTRY:-https://ohpm.openharmony.cn/ohpm/}"
PRODUCT_NAME="${PRODUCT_NAME:-default}"
FT_SDK_PRODUCT_NAME="${FT_SDK_PRODUCT_NAME:-ft_sdk}"
FT_SDK_EXT_PRODUCT_NAME="${FT_SDK_EXT_PRODUCT_NAME:-ft_sdk_ext}"
FT_NATIVE_PRODUCT_NAME="${FT_NATIVE_PRODUCT_NAME:-ft_native}"
BUILD_TARGET="${BUILD_TARGET:-default}"
MODULE_TYPE="${1:-agent}"
OHPM_PUBLISH_ID_VALUE="${OHPM_PUBLISH_ID:-${PUBLISH_ID:-}}"
OHPM_KEY_PATH_VALUE="${OHPM_KEY_PATH:-${KEY_PATH:-}}"
OHPM_KEY_PASSPHRASE_VALUE="${OHPM_KEY_PASSPHRASE:-${KEY_PASSPHRASE:-}}"
# Toggle whether this script should try to preload the publish key into ssh-agent.
OHPM_USE_SSH_AGENT_VALUE="${OHPM_USE_SSH_AGENT:-1}"

if [[ "$MODULE_TYPE" != "agent" && "$MODULE_TYPE" != "ft_sdk_ext" && "$MODULE_TYPE" != "native" && "$MODULE_TYPE" != "all" ]]; then
  echo "Usage: $0 [agent|ft_sdk_ext|native|all]"
  echo "  agent: build and publish ft_sdk + ft_sdk_ext"
  echo "  ft_sdk_ext: build and publish ft_sdk_ext only"
  echo "  native: build and publish ft_native"
  echo "  all: build and publish ft_sdk + ft_sdk_ext + ft_native"
  exit 1
fi

if [[ -n "${OHPM_BIN:-}" ]]; then
  if [[ "$OHPM_BIN" == */* ]]; then
    if [[ ! -x "$OHPM_BIN" || -d "$OHPM_BIN" ]]; then
      echo "Error: OHPM_BIN is set but not executable or not found: $OHPM_BIN"
      exit 1
    fi
  elif command -v "$OHPM_BIN" >/dev/null 2>&1; then
    OHPM_BIN="$(command -v "$OHPM_BIN")"
  else
    echo "Error: OHPM_BIN is set but not executable or not found: $OHPM_BIN"
    exit 1
  fi
elif command -v ohpm >/dev/null 2>&1; then
  OHPM_BIN="$(command -v ohpm)"
elif [[ -x "/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm" ]]; then
  OHPM_BIN="/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm"
else
  echo "Error: ohpm command not found. Set OHPM_BIN or add ohpm to PATH"
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
PREVIOUS_KEY_PASSPHRASE_SET=0
PREVIOUS_CRYPTO_PATH=""
PREVIOUS_CRYPTO_PATH_SET=0
SHOULD_RESTORE_KEY_PASSPHRASE=0
STARTED_SSH_AGENT=0
SSH_ASKPASS_SCRIPT=""
cleanup() {
  if [[ -n "$PREVIOUS_REGISTRY" ]]; then
    "$OHPM_BIN" config set registry "$PREVIOUS_REGISTRY" >/dev/null 2>&1 || true
  fi
  if [[ "$SHOULD_RESTORE_KEY_PASSPHRASE" -eq 1 ]]; then
    if [[ "$PREVIOUS_KEY_PASSPHRASE_SET" -eq 1 ]]; then
      "$OHPM_BIN" config set key_passphrase "$PREVIOUS_KEY_PASSPHRASE" >/dev/null 2>&1 || true
    else
      "$OHPM_BIN" config delete key_passphrase >/dev/null 2>&1 || true
    fi

    if [[ "$PREVIOUS_CRYPTO_PATH_SET" -eq 1 ]]; then
      "$OHPM_BIN" config set crypto_path "$PREVIOUS_CRYPTO_PATH" >/dev/null 2>&1 || true
    else
      "$OHPM_BIN" config delete crypto_path >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$STARTED_SSH_AGENT" -eq 1 && -n "${SSH_AGENT_PID:-}" ]]; then
    ssh-agent -k >/dev/null 2>&1 || true
  fi
  # The askpass helper contains the passphrase bridge for ssh-add, so always delete it.
  rm -f "$SSH_ASKPASS_SCRIPT"
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

verify_key_passphrase() {
  if [[ -z "$OHPM_KEY_PASSPHRASE_VALUE" ]]; then
    return
  fi

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "Warning: ssh-keygen not found; skipping private key passphrase verification"
    return
  fi

  local configured_key_path
  configured_key_path="$("$OHPM_BIN" config get key_path 2>/dev/null | tail -n 1 | tr -d '\r')"
  if [[ -z "$configured_key_path" || "$configured_key_path" == "undefined" || "$configured_key_path" == "null" ]]; then
    echo "Warning: key_path is empty after configuration; skipping private key passphrase verification"
    return
  fi

  if ! ssh-keygen -y -P "$OHPM_KEY_PASSPHRASE_VALUE" -f "$configured_key_path" >/dev/null 2>&1; then
    echo "Error: OHPM_KEY_PASSPHRASE cannot unlock the configured private key:"
    echo "  $configured_key_path"
    echo "Check that OHPM_KEY_PATH points to the expected key and OHPM_KEY_PASSPHRASE is correct."
    exit 1
  fi
}

set_key_passphrase() {
  if [[ -z "$OHPM_KEY_PASSPHRASE_VALUE" ]]; then
    return
  fi

  local existing_key_passphrase
  if "$OHPM_BIN" config get key_passphrase >/dev/null 2>&1; then
    existing_key_passphrase="$("$OHPM_BIN" config get key_passphrase 2>/dev/null | tail -n 1 | tr -d '\r')"
    if [[ -n "$existing_key_passphrase" && "$existing_key_passphrase" != "undefined" && "$existing_key_passphrase" != "null" ]]; then
      if [[ "$existing_key_passphrase" == security:* ]]; then
        PREVIOUS_KEY_PASSPHRASE="$existing_key_passphrase"
        PREVIOUS_KEY_PASSPHRASE_SET=1
      else
        echo "Warning: found plaintext ohpm key_passphrase; it will be cleared after publish"
      fi
    fi
  fi

  if "$OHPM_BIN" config get crypto_path >/dev/null 2>&1; then
    PREVIOUS_CRYPTO_PATH="$("$OHPM_BIN" config get crypto_path 2>/dev/null | tail -n 1 | tr -d '\r')"
    if [[ -n "$PREVIOUS_CRYPTO_PATH" && "$PREVIOUS_CRYPTO_PATH" != "undefined" && "$PREVIOUS_CRYPTO_PATH" != "null" ]]; then
      PREVIOUS_CRYPTO_PATH_SET=1
    fi
  fi

  local crypto_path="$WORK_DIR/ohpm-crypto"
  local ohpm_root
  ohpm_root="$(cd "$(dirname "$OHPM_BIN")/.." && pwd)"
  local ohpm_crypto_module="$ohpm_root/lib/core/config-encrypt/crypto"
  if [[ ! -f "$ohpm_crypto_module/index.js" ]]; then
    echo "Error: unable to find ohpm crypto module at $ohpm_crypto_module"
    exit 1
  fi

  local encrypted_passphrase
  encrypted_passphrase="$(
    OHPM_CRYPTO_MODULE_FOR_NODE="$ohpm_crypto_module" \
      OHPM_CRYPTO_PATH_FOR_NODE="$crypto_path" \
      OHPM_KEY_PASSPHRASE_FOR_NODE="$OHPM_KEY_PASSPHRASE_VALUE" \
      "$NODE_BIN" <<'NODE'
const cryptoModulePath = process.env.OHPM_CRYPTO_MODULE_FOR_NODE;
const cryptoPath = process.env.OHPM_CRYPTO_PATH_FOR_NODE;
const passphrase = process.env.OHPM_KEY_PASSPHRASE_FOR_NODE;

(async () => {
  const ohpmCrypto = require(cryptoModulePath);
  await ohpmCrypto.createCrypto(cryptoPath);
  const crypto = ohpmCrypto.loadCustomCrypto(cryptoPath);
  if (!crypto) {
    throw new Error(`failed to load ohpm crypto component: ${cryptoPath}`);
  }
  try {
    process.stdout.write(crypto.encrypt(passphrase));
  } finally {
    crypto.destroy();
  }
})().catch((error) => {
  console.error(error && error.message ? error.message : error);
  process.exit(1);
});
NODE
  )"

  if [[ "$encrypted_passphrase" != security:* ]]; then
    echo "Error: failed to encrypt ohpm key_passphrase"
    exit 1
  fi

  SHOULD_RESTORE_KEY_PASSPHRASE=1
  echo "Setting encrypted ohpm key_passphrase from environment variable"
  "$OHPM_BIN" config set crypto_path "$crypto_path" >/dev/null
  "$OHPM_BIN" config set key_passphrase "$encrypted_passphrase" >/dev/null
}

ensure_ssh_agent() {
  local normalized_use_ssh_agent
  normalized_use_ssh_agent="$(printf '%s' "$OHPM_USE_SSH_AGENT_VALUE" | tr '[:upper:]' '[:lower:]')"
  if [[ "$normalized_use_ssh_agent" != "1" && "$normalized_use_ssh_agent" != "true" && "$normalized_use_ssh_agent" != "yes" ]]; then
    return
  fi

  if ! command -v ssh-agent >/dev/null 2>&1 || ! command -v ssh-add >/dev/null 2>&1; then
    echo "Warning: ssh-agent or ssh-add not found; continuing without ssh-agent"
    return
  fi

  if [[ -z "${SSH_AUTH_SOCK:-}" ]] || ! ssh-add -l >/dev/null 2>&1; then
    echo "Starting temporary ssh-agent for publish"
    eval "$(ssh-agent -s)" >/dev/null
    STARTED_SSH_AGENT=1
  else
    # Reuse an existing agent when available so repeated publishes stay non-interactive.
    echo "Using existing ssh-agent"
  fi

  local configured_key_path
  configured_key_path="$("$OHPM_BIN" config get key_path 2>/dev/null | tail -n 1 | tr -d '\r')"
  if [[ -z "$configured_key_path" || "$configured_key_path" == "undefined" || "$configured_key_path" == "null" ]]; then
    echo "Warning: key_path is empty after configuration; skipping ssh-agent setup"
    return
  fi

  if [[ -n "$OHPM_KEY_PASSPHRASE_VALUE" ]]; then
    # Force ssh-add to consume the passphrase via SSH_ASKPASS so the script can run non-interactively.
    SSH_ASKPASS_SCRIPT="$WORK_DIR/ssh-askpass.sh"
    printf '%s\n' '#!/bin/sh' 'printf %s "$SSH_KEY_PASSPHRASE_FOR_AGENT"' > "$SSH_ASKPASS_SCRIPT"
    chmod 700 "$SSH_ASKPASS_SCRIPT"

    echo "Loading publish key into ssh-agent via SSH_ASKPASS"
    if ! SSH_KEY_PASSPHRASE_FOR_AGENT="$OHPM_KEY_PASSPHRASE_VALUE" \
      SSH_ASKPASS="$SSH_ASKPASS_SCRIPT" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY="${DISPLAY:-dummy}" \
      ssh-add "$configured_key_path" </dev/null >/dev/null; then
      echo "Warning: failed to load publish key into ssh-agent; continuing with ohpm direct key usage"
    fi
    return
  fi

  # Fall back to regular ssh-add behavior when no passphrase is provided by the environment.
  echo "Loading publish key into ssh-agent"
  if ! ssh-add "$configured_key_path"; then
    echo "Warning: failed to load publish key into ssh-agent; continuing with ohpm direct key usage"
  fi
}

set_registry() {
  if "$OHPM_BIN" config get registry >/dev/null 2>&1; then
    PREVIOUS_REGISTRY="$("$OHPM_BIN" config get registry 2>/dev/null | tail -n 1 | tr -d '\r')"
  fi

  echo "Setting ohpm registry to: $REGISTRY"
  "$OHPM_BIN" config set registry "$REGISTRY"
}

product_for_module() {
  local module_name="$1"

  case "$module_name" in
    ft_sdk)
      echo "$FT_SDK_PRODUCT_NAME"
      ;;
    ft_sdk_ext)
      echo "$FT_SDK_EXT_PRODUCT_NAME"
      ;;
    ft_native)
      echo "$FT_NATIVE_PRODUCT_NAME"
      ;;
    *)
      echo "$PRODUCT_NAME"
      ;;
  esac
}

build_har() {
  local module_name="$1"
  local build_module="${module_name}@${BUILD_TARGET}"
  local product_name
  product_name="$(product_for_module "$module_name")"

  echo "Building HAR for ${module_name} with product ${product_name}..."
  (
    cd "$ROOT_DIR"
    "$NODE_BIN" "$HVIGOR_JS" --mode module -p product="$product_name" -p module="$build_module" clean --analyze=normal
    "$NODE_BIN" "$HVIGOR_JS" --mode module -p product="$product_name" -p module="$build_module" assembleHar --analyze=normal --parallel
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
  local product_name
  product_name="$(product_for_module "$module_name")"
  local built_har="$ROOT_DIR/${module_name}/build/${product_name}/outputs/${BUILD_TARGET}/${module_name}.har"
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
  verify_key_passphrase
  set_key_passphrase
  ensure_ssh_agent
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

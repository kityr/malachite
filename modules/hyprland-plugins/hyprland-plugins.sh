#!/usr/bin/env bash
set -euo pipefail

log() { printf '\033[1;32m[hyprland-plugins]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[hyprland-plugins]\033[0m Warning: %s\n' "$*"; }
err() { printf '\033[1;31m[hyprland-plugins]\033[0m Error: %s\n' "$*" >&2; }

CONFIG="$1"

DEST_DIR=$(printf '%s' "${CONFIG}" | jq -r '.destination // "/usr/lib64/hyprland/plugins"')
mkdir -p "${DEST_DIR}"

# Number of plugins
PLUGIN_COUNT=$(printf '%s' "${CONFIG}" | jq '.plugins | length // 0')

if [ "${PLUGIN_COUNT}" -eq 0 ]; then
    warn "No plugins specified in hyprland-plugins module."
    exit 0
fi

BUILD_ROOT=$(mktemp -d /tmp/hypr-plugins-build.XXXXXX)
trap 'rm -rf "${BUILD_ROOT}"' EXIT

log "Installing plugins into ${DEST_DIR} (Total: ${PLUGIN_COUNT})"

for ((i = 0; i < PLUGIN_COUNT; i++)); do
    PLUGIN_JSON=$(printf '%s' "${CONFIG}" | jq -c ".plugins[$i]")
    
    # Handle string format (just the URL) or object format
    if printf '%s' "${PLUGIN_JSON}" | jq -e 'type == "string"' >/dev/null 2>&1; then
        URL=$(printf '%s' "${PLUGIN_JSON}" | jq -r '.')
        REF=""
        SUBDIR=""
        CUSTOM_BUILD=""
        OUTPUT=""
    else
        URL=$(printf '%s' "${PLUGIN_JSON}" | jq -r '.url')
        REF=$(printf '%s' "${PLUGIN_JSON}" | jq -r '.ref // ""')
        SUBDIR=$(printf '%s' "${PLUGIN_JSON}" | jq -r '.subdir // ""')
        CUSTOM_BUILD=$(printf '%s' "${PLUGIN_JSON}" | jq -r '.build // ""')
        OUTPUT=$(printf '%s' "${PLUGIN_JSON}" | jq -r '.output // ""')
    fi

    REPO_NAME=$(basename "${URL}" .git)
    REPO_DIR="${BUILD_ROOT}/${REPO_NAME}"

    log "----------------------------------------------------"
    log "Processing plugin: ${REPO_NAME} (${URL})"

    # Clone repository
    if [ -n "${REF}" ]; then
        log "Cloning ${URL} at ref ${REF}..."
        git clone --depth 1 --branch "${REF}" "${URL}" "${REPO_DIR}" || {
            git clone "${URL}" "${REPO_DIR}"
            (cd "${REPO_DIR}" && git checkout "${REF}")
        }
    else
        log "Cloning ${URL} (latest)..."
        git clone --depth 1 "${URL}" "${REPO_DIR}"
    fi

    TARGET_DIR="${REPO_DIR}"
    if [ -n "${SUBDIR}" ]; then
        TARGET_DIR="${REPO_DIR}/${SUBDIR}"
    fi

    if [ ! -d "${TARGET_DIR}" ]; then
        err "Target directory ${TARGET_DIR} does not exist!"
        exit 1
    fi

    cd "${TARGET_DIR}"

    # Build plugin
    if [ -n "${CUSTOM_BUILD}" ]; then
        log "Running custom build command: ${CUSTOM_BUILD}"
        eval "${CUSTOM_BUILD}"
    elif [ -f "Makefile" ] || [ -f "makefile" ]; then
        log "Found Makefile. Building with make..."
        make all || make
    elif [ -f "CMakeLists.txt" ]; then
        log "Found CMakeLists.txt. Building with cmake..."
        cmake -B build -DCMAKE_BUILD_TYPE=Release
        cmake --build build -j"$(nproc)"
    elif [ -f "meson.build" ]; then
        log "Found meson.build. Building with meson & ninja..."
        meson setup build --buildtype=release
        ninja -C build
    else
        err "No Makefile, CMakeLists.txt, or meson.build found in ${TARGET_DIR}!"
        exit 1
    fi

    # Install output .so files
    SO_COPIED=0
    if [ -n "${OUTPUT}" ] && [ -f "${TARGET_DIR}/${OUTPUT}" ]; then
        log "Installing specified output: ${OUTPUT} -> ${DEST_DIR}/"
        install -m 755 "${TARGET_DIR}/${OUTPUT}" "${DEST_DIR}/"
        SO_COPIED=$((SO_COPIED + 1))
    else
        # Find all .so files generated in this repo target
        while IFS= read -r so_file; do
            filename=$(basename "${so_file}")
            log "Installing shared object: ${filename} -> ${DEST_DIR}/"
            install -m 755 "${so_file}" "${DEST_DIR}/${filename}"
            SO_COPIED=$((SO_COPIED + 1))
        done < <(find "${TARGET_DIR}" -type f -name "*.so")
    fi

    if [ "${SO_COPIED}" -eq 0 ]; then
        err "Build completed but no .so files found in ${TARGET_DIR}!"
        exit 1
    fi

    log "Successfully built and installed ${REPO_NAME} (${SO_COPIED} binary installed)."
done

log "All Hyprland plugins successfully installed into ${DEST_DIR}."

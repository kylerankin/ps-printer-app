# BuildStream runs in the pinned freedesktop-sdk builder image, the same one
# fsdk-containers and the other printer applications build with.
bst2_image := env("BST2_IMAGE", "registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:64eb0b4930d57a92710822898fb73af6cc1ae35d")
image_ref := env("IMAGE_REF", "ghcr.io/projectbluefin/ps-printer-app:build")

default:
    @just --list

# BST_FLAGS adds global bst options, e.g. CI's --config /src/ci/buildstream.conf.
# BST_CACHE_DIR selects another local artifact cache (default ~/.cache/buildstream).
bst *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    cache_dir="${BST_CACHE_DIR:-${HOME}/.cache/buildstream}"
    mkdir -p "${cache_dir}"
    podman run --rm \
        --privileged \
        --device /dev/fuse \
        --network=host \
        -v "{{ justfile_directory() }}:/src:rw" \
        -v "${cache_dir}:/root/.cache/buildstream:rw" \
        -w /src \
        "{{ bst2_image }}" \
        bash -c 'bst "$@"' -- --no-interactive ${BST_FLAGS:-} {{ ARGS }}

# Resolve the complete graph without building it. The printing base already
# stages avahi-printing's avahi-daemon; FSDK's components/avahi.bst installs
# the same files, so the graph must never contain it.
#
# tests/fsdk-contract.sh checks the fsdk-containers printing-base consumer
# contract against the resolved graph: one CUPS artifact owner, one pinned
# junction, no local CUPS source or patch copies, and a runtime-only compose.
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    names="$(just bst show --deps all --format '%{name}' oci/ps-printer-app.bst)"
    printf '%s\n' "$names" | tests/fsdk-contract.sh --graph -

fetch:
    #!/usr/bin/env bash
    set -euo pipefail
    for attempt in 1 2 3; do
        if just bst source fetch --deps all oci/ps-printer-app.bst; then
            exit 0
        fi
        echo "source fetch failed (attempt ${attempt}/3)" >&2
        if [[ "$attempt" -lt 3 ]]; then sleep 15; fi
    done
    exit 1

build:
    #!/usr/bin/env bash
    set -euo pipefail
    just bst build oci/ps-printer-app.bst
    just export

export:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .build-out
    just bst artifact checkout oci/ps-printer-app.bst --directory /src/.build-out
    IMAGE_ID=$(podman pull -q oci:.build-out)
    rm -rf .build-out
    podman tag "$IMAGE_ID" "{{ image_ref }}"

# Appliance lifecycle, IPP and a job through to a socket sink.
verify-core:
    IMAGE="{{ image_ref }}" tests/core-appliance.sh

# PDF to vector PostScript, and HPLIP hpps PIN jobs, printed through to a socket sink.
verify-routes:
    IMAGE="{{ image_ref }}" tests/print-routes.sh

# Driver and PPD payload, and the web-interface test page through the socket backend.
verify-payload:
    IMAGE="{{ image_ref }}" tests/core-payload.sh

# Foomatic-RIP PIN jobs: an OEM PostScript queue turns a PIN into its locked print JCL.
verify-pin:
    IMAGE="{{ image_ref }}" tests/foomatic-pin.sh

# Two named instances side by side, the default name, and the entrypoint's
# refusals of a bad instance name, PORT or state volume.
verify-instances:
    IMAGE="{{ image_ref }}" tests/instance-isolation.sh

# USB quirk seeding: the seeded table under USB_QUIRK_DIR/usb is the packaged
# default from the installed CUPS path, and a user edit survives a restart.
verify-usb-quirks:
    IMAGE="{{ image_ref }}" tests/usb-quirks.sh

# The image is composed from runtime domains only: the printing base it builds
# on is a devel stack, so headers, static libraries and pkg-config/CMake files
# must not leak into it (fsdk-containers docs/skills/printing-base.md, rule 5).
verify-no-devel:
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE="{{ image_ref }}"
    root="$(mktemp -d)"
    ctr="$(podman create "${IMAGE}" /none)"
    trap 'podman rm "${ctr}" >/dev/null; rm -rf "${root}"' EXIT
    podman export "${ctr}" | tar -C "${root}" -xf -
    # License notices under usr/share/licenses are kept and never count as devel content.
    bad="$(cd "${root}" && find . -path ./usr/share/licenses -prune -o \( -path ./usr/include -o -name '*.a' -o -name '*.la' \
          -o -type d -name pkgconfig -o -type d -name cmake \) -print -quit)"
    [ -z "${bad}" ] || { echo "devel content in ${IMAGE}: ${bad}" >&2; exit 1; }
    echo "OK: ${IMAGE} carries no devel content"

# The contract check above is only worth what it rejects. This breaks each
# invariant it guards in a scratch copy of the graph and requires the check to
# fail, so a check that stopped working cannot pass as a green validate.
verify-contract:
    tests/fsdk-contract-test.sh

# Verify a built image (run `just build` first).
verify:
    just validate
    just verify-contract
    just verify-no-devel
    just verify-core
    just verify-routes
    just verify-payload
    just verify-pin
    just verify-instances
    just verify-usb-quirks

# SPDX SBOM of the image graph for releases (run `just fetch` first).
sbom:
    #!/usr/bin/env bash
    set -euo pipefail
    cache_dir="${BST_CACHE_DIR:-${HOME}/.cache/buildstream}"
    mkdir -p "${cache_dir}" "${HOME}/.cache/pip"
    revision="$(git rev-parse HEAD)"
    podman run --rm \
        --privileged \
        --device /dev/fuse \
        --network=host \
        -v "{{ justfile_directory() }}:/src:rw" \
        -v "${cache_dir}:/root/.cache/buildstream:rw" \
        -v "${HOME}/.cache/pip:/root/.cache/pip:rw" \
        -w /src \
        -e REVISION="$revision" \
        "{{ bst2_image }}" \
        bash -c '
            pip install --quiet git+https://gitlab.com/BuildStream/buildstream-sbom.git@0706fec3bedf6f73bd9d2fed32c2aed585feef8d
            buildstream-sbom oci/ps-printer-app.bst \
                --spdx-name ps-printer-app \
                --spdx-namespace "https://github.com/projectbluefin/ps-printer-app/sbom/${REVISION}" \
                --spdx-creator "Tool: buildstream-sbom" \
                --spdx-creator "Organization: projectbluefin" \
                --deps all \
                --output /src/ps-printer-app.spdx.json
        '

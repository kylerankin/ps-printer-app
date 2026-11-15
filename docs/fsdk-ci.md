# Native FSDK image validation

`.github/workflows/fsdk-ci.yml` builds and verifies the image on every pull
request to `main`, in the merge queue, and on manual dispatch. Both native
x86_64 and AArch64 jobs have a six-hour limit. A new commit cancels the
previous pull-request run; merge-queue and dispatch runs are not cancelled.

Full builds restore BuildStream's local cache (`~/.cache/buildstream/cas`,
`artifacts`, `source_protos`) from the Actions cache, one entry per arch.
`ci/buildstream.conf` sets no cache quota, because BuildStream fails builds at
quota. Only `.github/workflows/bst-cache.yml` saves the cache (saved only when an
arch fits in 9000 MB uncompressed; a larger cache is skipped with a warning): on pushes to
`main` that touch graph inputs, nightly, and on dispatch.
Reset it with `gh cache delete --all -R projectbluefin/ps-printer-app`.

Both jobs inherit only `contents: read`. Checkout does not persist credentials,
and the workflow has no registry login, secrets, publishing step, or privileged
`pull_request_target` trigger. Public builder images and sources must be readable
without registry credentials. FSDK validation does not trigger a release
workflow.

## Release

`.github/workflows/registry-actions.yml` runs on every push to `main` (and on
dispatch from `main`). Every commit there came through the merge queue, so
it already passed the full native build and `just verify` above. The
`metadata` job reads `VERSION`, derives the `io.projectbluefin.fsdk.version`
and `.ref` labels from the freedesktop-sdk junction of the pinned
fsdk-containers commit (`scripts/fsdk-pin.sh`, which `just validate` already
ran on the pull request through `tests/source-pins.sh`), and refuses a commit whose `sha-<commit>` tag already
exists. `build` rebuilds and verifies both architectures and stamps those
labels plus the revision and creation time; `publish`, the only job with
`packages: write` and `id-token: write`, needs both. The index, both
architecture manifests and the `just sbom` SPDX SBOM are signed with keyless
cosign, the index gets a build-provenance attestation, and the workflow
verifies all of it from the registry by digest before tagging: immutable
`sha-<commit>`, then the moving `<VERSION>`, `<VERSION>-x86_64`,
`<VERSION>-aarch64` and `stable`. Reverting a pull request is the rollback.

Every job is skipped until the repository variable `PS_PUBLISH_APPROVED` is
`true`: publishing is held for the PPD-upload security sign-off (#198). See the
README for lifting the hold.

The upstream Snap/Rock CI, the scheduled manifest updater and the Rock registry
workflow are removed; `snap/` and `rockcraft.yaml` stay only as references.

## The shared printing base

The graph builds on fsdk-containers' shared printing base, junctioned at a pinned
commit in `elements/fsdk-containers.bst`. `fsdk-containers.bst:printing/base.bst`
is the one provider of CUPS, cups-filters, libcupsfilters, libppd, ghostscript,
mutool, avahi-printing, PAPPL and pappl-retrofit, including their printer-app
patches; this repository adds no FSDK junction or patches of its own and reaches
FSDK only through `fsdk-containers.bst:freedesktop-sdk.bst:...`. The contract is
fsdk-containers' `docs/skills/printing-base.md`.

- The base is a devel stack. `printer-app/core-runtime.bst` composes the image
  from runtime domains only, and `just verify-no-devel` fails on headers, static
  or libtool archives, and pkg-config or CMake directories in the image.
- The OCI element applies the pinned shared slim-printing recipe and its build
  gate before the appliance-specific removals. `just verify-slim` checks the
  shared and appliance-specific forbidden paths again in the exported image.
  Bash, Python and ordinary Python bytecode remain available to the appliance.
  The OCI element includes `fsdk-containers.bst:include/slim-printing.yml`
  from the pinned junction; there is no local copy to keep in sync.
- `just build` resolves the runtime-layer key from the pinned junction, verifies
  the published digest against the exact main-branch signing workflow, and
  stages that same digest as the OCI parent. It requires `cosign` and `skopeo`
  on the host. The full runtime filesystem remains the child layer input.
  CI compares the first layer digests for both architectures. The retained
  `.build-out` layout is published without a container-storage round trip.
- `just validate` checks the contract itself against the resolved graph:
  `tests/fsdk-contract.sh` fails on a second FSDK junction, a CUPS stack
  element outside the junction (a second CUPS owner), a patch staged by an
  element, a source with no immutable pin, or a runtime compose that no longer
  excludes the devel domains. `tests/fsdk-contract-test.sh`, which `just
  validate` runs first (and `just verify-contract` runs on its own), breaks each
  of those invariants in a scratch copy of the
  graph and requires the check to fail, so the gate cannot pass by going quiet.
- Before the full build, both workflows run `Seed printing base`: when the base
  is not already cached it pulls
  `ghcr.io/projectbluefin/printing-base-devel:<arch>-<full-key>`, verifies its
  keyless cosign signature, and only then extracts it into the local cache.
  The step never fails the job; any error is a `::warning::` and the base is
  built locally.
- Renovate (`renovate.json`, a `git-refs` custom manager) moves the junction
  `ref:` to the fsdk-containers `main` HEAD and automerges the bump through the
  merge queue once the required `FSDK (x86_64)` and `FSDK (aarch64)` checks pass.
  When the producer's pinned FSDK release changes, update
  `junction-files/fsdk-containers/include/fsdk-version.yml` to match the value
  its `just bst` wrapper generates from `elements/freedesktop-sdk.bst`. The
  include is gitignored upstream and must be staged into the junction here.

## Build interface

The prerequisite job checks the interface files below and reports a skip only
when the whole graph is absent; a partial graph fails it.

The workflow follows the Ghostscript appliance's build interface:

- `project.conf` and `elements/oci/ps-printer-app.bst` define the image graph.
- `Justfile` (or `justfile`) provides `bst`, `validate`, `build`, and `verify`
  recipes; `build` and `verify` must not depend on a `fetch` recipe.
- `just validate` checks the host-only contracts and resolves the graph.
- `just build` verifies and fetches the parent, builds and exports the OCI image.
  The cache refill calls `just prepare-parent` before its direct BuildStream build.
- `just verify` runs full appliance and payload verification, including executable
  `tests/core-appliance.sh`, `tests/core-payload.sh` and
  `tests/instance-isolation.sh`. The payload test must send a real IPP job through
  the driver/filter/socket backend, check format-specific output bytes, and require
  job completion. It must also cover the persistence and coexistence contracts from
  #4 and #5; `tests/instance-isolation.sh` runs two instances side by side. Synthetic
  echoes are not sufficient.
  `tests/foomatic-pin.sh` additionally sends a PIN-protected job to an OEM
  PostScript queue and requires the PPD's locked print JCL on the socket sink (#14).

A partial graph fails the prerequisite check instead of skipping native builds.
The prerequisite check only checks interface files; the recipes and tests must
implement the behavior above. Physical paper output remains unverified without
hardware.

Validate workflow edits with `actionlint .github/workflows/*.yml`. After
prerequisites land, both native jobs must
pass before claiming #6 is complete.

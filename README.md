# PostScript Printer Application

## INTRODUCTION

This repository contains a Printer Application for PostScript printers
that uses [PAPPL](https://www.msweet.org/pappl) to support IPP
printing from multiple operating systems. In addition, it uses the
resources of [cups-filters
2.x](https://github.com/OpenPrinting/cups-filters) (filter functions
in libcupsfilters, libppd) and
[pappl-retrofit](https://github.com/OpenPrinting/pappl-retrofit)
(encapsulating classic CUPS drivers in Printer Applications). This
work (or now the code of pappl-retrofit) is derived from the
[hp-printer-app](https://github.com/michaelrsweet/hp-printer-app).

Your contributions are welcome. Please post [issues and pull
requests](https://github.com/projectbluefin/ps-printer-app/issues) in
this repository. See [how issues and PRs work
here](https://github.com/projectbluefin/common/blob/main/docs/skills/label-workflow.md)
for what happens after an issue or pull request is opened.


### This Printer Application is a working model for

- A non-raster Printer Application: Destination format is PostScript,
  a high-level/vector format. Input data in PostScript or PDF is
  accepted and needed conversion is done without any inbetween raster
  steps.

- A Printer Application which uses the new filter functions of
  cups-filters 2.x. Filter functions are library functions derived
  from the CUPS filters and contain decades of development and
  refinement starting from the introduction of CUPS in 2000.

- A retro-fit Printer Application for classic CUPS drivers, in this
  case the simplest form of only PPD files for PostScript printers. It
  lists PPD files from repositories included in the Snap, loads the
  PPD needed for the actual printer, extracts options from the PPD to
  display them in the web interface, accepts job settings as IPP
  attributes, and inserts the PostScript code provided by the PPD
  correctly into the output data stream.

- A Printer Application which does not pass through raw (input format
  is printer's native format) jobs. To assure that always the
  PostScript code of the PPD file is inserted into the output stream,
  we call the printer's native format
  "application/vnd.printer-specific" which does not exist as input
  format, so "application/postscript" input is forced through the
  pstops() filter function.

- An expandable Printer Application: The user can add PPD files via the
  administration web interface to support additional printer models.

Further properties are:

- To avoid the need to re-invent the code for forking into sub-processes
  so that we can pass data through a sequence of filters, we create a
  filter function to send the data off to the printer and form a chain
  of the actually converting filter function (one of pstops() and
  pdftops()) with this filter function using the filterChain() filter
  function.

- For PWG/Apple Raster input we use raster callbacks so that the
  processing is streaming, allowing for large and even infinitely long
  jobs. We use libppd functions to insert the PPD option's PostScript
  code in the output stream and the filterPOpen() function to create a
  file descriptor for the libppd functions to send data off to the
  device.

- The PostScript Printer Application Snap has all PostScript PPD files
  of the [foomatic-db](https://github.com/OpenPrinting/foomatic-db)
  and [HPLIP](https://developers.hp.com/hp-linux-imaging-and-printing)
  projects built-in, so most PostScript printer PPDs which usually
  come with Linux Distributions. To avoid that this vast number of
  PPDs blows up the size of the Snap, we highly compress them using
  [pyppd](https://github.com/OpenPrinting/pyppd). Note that some PPDs
  use certain CUPS filters for extra functionality. These filters are
  included in the Snap, so the extra functionality is supported (in
  most cases PIN-protected printing). The user can add additional PPDs
  without needing to rebuild the Snap (see below).

- We use the printer's IEEE-1284 device ID to identify at first that
  it is a PostScript printer (via CMD: field) to see whether it is
  supported at all and only then check via make and model whether we
  explicitly support it with a PPD. PostScript printers for which
  there is no PPD get a generic PPD assigned. By the check of the CMD:
  field before make/model lookup we assure that if PostScript is
  provided by an add-on module that the module is actually installed.

- Standard job IPP attributes are mapped to the PPD option settings
  best fitting to them so that users can print from any type of client
  (like for example a phone or IoT device) which only supports
  standard IPP attributes and cannot retrive the PPD options. Trays,
  media sizes, media types, and duplex can get mapped easily, but when
  it comes to color and quality it gets more complex, as relevant
  options differ a lot in the PPD files. Here we use an algorithm
  which automatically (who wants hand-edit ~10000 PPDs for the
  assignments) finds the right set of option settings for each
  combination of `print-color-mode` (`color`/`monochrome`),
  `print-quality` (`draft`/`normal`/`high`), and
  `print-content-optimize`
  (`auto`/`photo`/`graphics`/`text`/`text-and-graphics`) in the PPD of
  the current printer. So you have easy access to the full quality or
  speed of your printer without needing to deal with printer-specific
  option settings (the original options are still accessible via web
  admin interface).

- The printer capabilities for a given printer model (a "driver" in
  the Printer Application) are not static throughout the life of the
  print queue set up in the Printer Application. The user can
  configure via a page in the web admin interface which hardware
  accessories (extra paper trays, duplex unit, finishers, ...) are
  installed on the printer and the Printer Application updates the
  driver data structure and with this the printer capabilities. The
  response to a get-printer-attributes IPP request gets updated
  appropriately.

- PostScript is a full-fledged programming language and many PostScript
  printers allow querying settings of options and the presence of
  installable hardware accessories executing appropriate PostScript
  code. If a setting can get queried, the manufacturer puts the needed
  PostScript code into the PPD file, together with the queriable option.
  These queries are supported by the web interface of the Printer
  Application.

- Available printer devices are discovered (and used) with CUPS'
  backends and not with PAPPL's own backends. This way quirk
  workarounds for USB printers with compatibility problems are used
  (and are editable) and PostScript output can get sent to the printer
  via IPP, IPPS (encrypted!), and LPD in addition to socket (usually
  port 9100). The SNMP backend can get configured (community, address
  scope).

- If you have an unusual system configuration or a personal firewall
  your printer will perhaps not get discovered. In this situation the
  fully manual "Network Printer" entry in combination with the
  hostname/IP field can be helpful.


### Remark

- This Printer Application and its snapping is derived from the
  hp-printer-app, which uses the "avahi-observe" Snap interface to
  access DNS-SD. This does not work for registering printers. In this
  Printer Application this is already corrected to "avahi-control".


### To Do

- On the "Add PPD files" page in the list of already added user PPD
  files mark which ones are actually used by a printer which got set
  up in the Printer Application, to avoid that the user removes these
  files.

- Human-readable strings for vendor options (Needs support by PAPPL:
  [Issue #58: Localization
  support](https://github.com/michaelrsweet/pappl/issues/58))

- Internationalization/Localization (Needs support by PAPPL: [Issue
  #58: Localization
  support](https://github.com/michaelrsweet/pappl/issues/58))

- SNMP Ink level check via ps_status() function (Needs support by PAPPL:
  [Issue #83: CUPS does IPP and SNMP ink level polls via backends,
  PAPPL should have functions for
  this](https://github.com/michaelrsweet/pappl/issues/83))

- Build options for cups-filters, to build without libqpdf and/or
  without libppd, the former will allow to create the Snap of this
  Printer Application without downloading and building QPDF

## Project Bluefin FSDK OCI appliance

Upstream `snap/` and `rockcraft.yaml` remain as source references, but this
fork builds and releases only the BuildStream OCI image
`ghcr.io/projectbluefin/ps-printer-app`, on the shared fsdk-containers printing
base (see [docs/fsdk-ci.md](docs/fsdk-ci.md)). The Snap and Rock sections below
describe upstream packaging, not this fork's releases.

On native x86_64 or aarch64, with Podman, FUSE and `just` available:

```sh
just validate
just build
just verify
```

Issues and pull requests are handled with Prow `/commands`; see
[how issues and PRs work here](https://github.com/projectbluefin/common/blob/main/docs/skills/label-workflow.md).

PRs target `main` and merge through the merge queue, whose required native
x86_64 and aarch64 build and `just verify` checks gate every commit. Renovate
keeps the fsdk-containers junction (`elements/fsdk-containers.bst`) on
fsdk-containers `main` and automerges each bump once those checks pass.

Every push to `main` makes `registry-actions.yml` rebuild and verify both
architectures and publish an amd64+arm64 GHCR index, keyless cosign-signed
(index and both architecture manifests), with a signed SPDX SBOM and build
provenance. The workflow derives the `io.projectbluefin.fsdk.version` and
`io.projectbluefin.fsdk.ref` labels from the junction at publish time; nothing
FSDK-specific is committed beyond the junction ref. It pushes, signs, attests
and verifies everything by digest, and only then tags it: the immutable
`sha-<commit>` tag, and the moving `<VERSION>` (`VERSION` is the foomatic-db
snapshot date plus a packaging revision, e.g. `20240504-20`),
`<VERSION>-x86_64`, `<VERSION>-aarch64` and `stable` tags (`stable` is consumed
by ChairLift's Podman `AutoUpdate=registry` quadlets). A failed check leaves no
tagged, unsigned image. Reverting the pull request is the rollback.

Publishing is held until the PPD-upload security sign-off
([#45](https://github.com/projectbluefin/ps-printer-app/issues/45)): every
`registry-actions.yml` job is skipped unless the repository variable
`PS_PUBLISH_APPROVED` is `true`. To lift the hold, a maintainer runs
`gh variable set PS_PUBLISH_APPROVED --body true -R projectbluefin/ps-printer-app`,
dispatches `registry-actions.yml` on `main` (or merges the next pull request),
and then makes the new `ghcr.io/projectbluefin/ps-printer-app` package public
in its package settings (Actions cannot change package visibility; check it with
`skopeo list-tags docker://ghcr.io/projectbluefin/ps-printer-app`, which needs no
login once the package is public).

The image runs as `nonroot` (65532:65532) on the host network and keeps all
state under `/var/lib/ps-printer-app`. Give each instance its own `PORT`,
state volume and `PRINTER_APP_INSTANCE`, the name it advertises for DNS-SD:

```sh
mkdir -p state-a
podman unshare chown -R 65532:65532 state-a
podman run -d --name ps-printer-app-a --network host \
  -e PORT=18080 -e PRINTER_APP_INSTANCE=lab-a \
  -v "$PWD/state-a:/var/lib/ps-printer-app:Z" \
  ghcr.io/projectbluefin/ps-printer-app:<version>
```

PAPPL serves IPP and the web interface on one port, so on the host network the
web administration pages are reachable by every client that can reach the IPP
port; the entrypoint prints a `NOTICE` saying so whenever the web interface is
enabled. Three variables control web administration:

| Variable | Forwarded as | Accepted values |
| --- | --- | --- |
| `PRINTER_APP_SERVER_OPTIONS` | `-o server-options=…` | Comma-separated PAPPL server options from the allow-list: `no-web-interface`. |
| `PRINTER_APP_AUTH_SERVICE` | `-o auth-service=…` | A PAM service name; refused (exit `78`) while the base builds PAPPL without PAM. |
| `PRINTER_APP_ADMIN_GROUP` | `-o admin-group=…` | A group from the image's `/etc/group`; requires `PRINTER_APP_AUTH_SERVICE`. |

`PRINTER_APP_SERVER_OPTIONS=no-web-interface` turns the web pages off while IPP
printing and DNS-SD keep working; manage printers from inside the container with
`podman exec ps-printer-app-a ps-printer-app -u ipp://127.0.0.1:18080/ipp/system … add`.
`PRINTER_APP_AUTH_SERVICE` is refused outright because the shared printing base
builds PAPPL with `--disable-libpam`, so forwarding it would answer every
administration request with `401`. An unlisted server option (such as `no-tls`
or `none`), a malformed name, a group the image cannot resolve, or a group
without an auth service exits `64` (malformed) or `78` (cannot be honoured).
`tests/entrypoint-validation.sh` covers those rejections on the host.

State, instance names and rootless USB access, including what is not verified
on hardware, are described in
[docs/state-and-device-isolation.md](docs/state-and-device-isolation.md). The
Rock section's `-v /dev/bus/usb:/dev/bus/usb:ro` examples describe the upstream
Rock image, not this one.



## THE SNAP

### Installing and building

To just run and use this Printer Application, simply install it from
the Snap Store:

```
sudo snap install --edge ps-printer-app
```

Then follow the instructions below for setting it up.

To build the Snap by yourself, in the main directory of this
repository run

```
snapcraft snap
```

This will download all needed packages and build the PostScript
Printer Application. Note that PAPPL (upcoming 1.0) and cups-filters
(upcoming 2.0) are pulled directly from their GIT repositories, as
there are no appropriate releases yet. This can also lead to the fact
that this Printer Application will suddenly not build any more.

NOTE: There is a bug in Ubuntu Groovy (20.10) that prevents it from
building Snaps, see [this discussion on the Snapcraft
forum](https://forum.snapcraft.io/t/build-fails-with-a-mksquashfs-error-cannot-pack-root-prime/). The
problem is already solved but did not make it into Groovy yet.

Any older (like 20.04) or newer (like 21.04) Ubuntu version should work.

To install the resulting Snap run

```
sudo snap install --dangerous ps-printer-app_1.0_amd64.snap
```


### Setting up

The Printer Application will automatically be started as a server daemon.

Enter the web interface

```
http://localhost:8000/
```

Use the web interface to add a printer. Supply a name, select the
discovered printer, then select make and model. Also set the installed
accessories, loaded media and the option defaults. Accessory
configuration and option defaults can also offen get polled from the
printer.

Then print PDF, PostScript, JPEG, Apple Raster, or PWG Raster files
with

```
ps-printer-app FILE
```

or print with CUPS, CUPS (and also cups-browsed) discover and treat
the printers set up with this Printer Application as driverless IPP
printers (IPP Everywhere and AirPrint).

You can also add PPD files without rebuilding the Snap, either by
using the "Add PPD files" button in the web interface or by manually
copying PPD files:

```
sudo cp PPDFILE /var/snap/ps-printer-app/common/ppd/
```

After manually copying (or removing) PPD files you need to restart the
server or in the web interface, on the "Add PPD files" page click the
"Refresh" button at the bottom. This adds the changes to the internal
driver list.

On the "Add Printer" page in the drop-down to select the driver,
user-added PPD files are marked "USER-ADDED". When setting up a
printer with automatic driver selection, user-added PPD files are
preferred.

`PPDFILE` in the command line above cannot only be a single PPD file
but any number of single PPD files, `.tar.gz` files containing PPDs
(in arbitrary directory structure) and PPD-gemerating executables
which are usually put into `/usr/lib/cups/driver`. You can also create
arbitrary sub-directory structures in
`/var/snap/ps-printer-app/current/ppd/` containing the mentioned types
of files. Only make sure to not put any executables there which do
anything else than listing and generating PPD files.

Note that with the web interface you can only manage individual PPDs
(uncompressed or compressed with `gzip`) in the
`/var/snap/ps-printer-app/current/ppd/` itself. Archives, executables,
or sub-directories are not shown and appropriate uploads not
accepted. This especially prevents adding executables without root
rights.

Any added PPD file must be for PostScript printers, as non-PostScript
PPD files are for CUPS drivers and so they would need additional files
in order to work and such files are not supported by this Printer
Application. The "Add PPD files" page shows warnings if such files get
uploaded.

See

```
ps-printer-app --help
```

for more options.

Use the "-o log-level=debug" argument for verbose logging in your
terminal window.

You can add files to `/var/snap/ps-printer-app/common/usb/` for
additional USB quirk rules. Edit the existing files only for quick
tests, as they get replaced at every update of the Snap (to introduce
new rules).

You can edit the `/var/snap/ps-printer-app/common/cups/snmp.conf` file
for configuring SNMP network printer discovery.

## THE ROCK (OCI CONTAINER IMAGE)

### Install from DockerHub

#### Prerequisites

**Docker Installed**: Ensure Docker is installed on your system. You can download it from the [official Docker website](https://www.docker.com/get-started).

#### Step-by-Step Guide

You can pull the `ps-printer-app` Docker image from either the GitHub Container Registry or Docker Hub.

**From GitHub Container Registry** <br>
To pull the image from the GitHub Container Registry, run the following command:
```sh
  sudo docker pull ghcr.io/openprinting/ps-printer-app:latest
```

Create a Docker volume:
```sh
  sudo docker volume create ps-printer-app
```

To run the container after pulling the image from the GitHub Container Registry, use:
```sh
  sudo docker run -d \
      --name ps-printer-app \
      --network host \
      -e PORT=<port> \
      -v ps-printer-app:/var/lib/ps-printer-app \
      -v /dev/bus/usb:/dev/bus/usb:ro \
      --device-cgroup-rule='c 189:* rmw' \
      ghcr.io/openprinting/ps-printer-app:latest
```

**From Docker Hub** <br>
Alternatively, you can pull the image from Docker Hub, by running:
```sh
  sudo docker pull openprinting/ps-printer-app
```

Create a Docker volume:
```sh
  sudo docker volume create ps-printer-app
```

To run the container after pulling the image from Docker Hub, use:
```sh
  sudo docker run -d \
      --name ps-printer-app \
      --network host \
      -e PORT=<port> \
      -v ps-printer-app:/var/lib/ps-printer-app \
      -v /dev/bus/usb:/dev/bus/usb:ro \
      --device-cgroup-rule='c 189:* rmw' \
      openprinting/ps-printer-app:latest
```

- `PORT` is an optional environment variable used to start the printer-app on a specified port. If not provided, it will start on the default port 8000 or, if port 8000 is busy, on 8001 and so on.
- **The container must be started in `--network host` mode** to allow the Printer-Application instance inside the container to access and discover printers available in the local network where the host system is in.
- Alternatively using the internal network of the Docker instance (`-p <port>:8000` instead of `--network host -e PORT=<port>`) only gives access to local printers running on the host system itself.
- `-v ps-printer-app:/var/lib/ps-printer-app` maps a volume for persistent storage.
- The following volume and device settings are crucial for USB printer access:
  - `-v /dev/bus/usb:/dev/bus/usb:ro` mounts the host's USB device directory read-only inside the container for USB printer access.
  - `--device-cgroup-rule='c 189:* rmw'` allows the container to read, write, and mknod to USB devices.

### Setting up and running a ps-printer-app container locally

#### Prerequisites

**Docker Installed**: Ensure Docker is installed on your system. You can download it from the [official Docker website](https://www.docker.com/get-started) or from the Snap Store:
```
sudo snap install docker
```

**Rockcraft**: Rockcraft should be installed. You can install Rockcraft using the following command:
```sh
  sudo snap install rockcraft --classic
```

**Skopeo**: Skopeo should be installed to compile `*.rock` files into Docker images. It comes bundled with Rockcraft, so no separate installation is required.

#### Step-by-Step Guide

**Build the ps-printer-app Rock**

The first step is to build the Rock from the `rockcraft.yaml`. This image will contain all the configurations and dependencies required to run ps-printer-app.

Open your terminal and navigate to the directory containing your `rockcraft.yaml` (base directory of this package), then run the following command:
```sh
  rockcraft pack -v
```

**Compile to Docker image**

Once the rock is built, you need to compile a docker image from it:
```sh
  sudo rockcraft.skopeo --insecure-policy copy oci-archive:<rock_image> docker-daemon:ps-printer-app:latest
```

Create a Docker volume:
```sh
  sudo docker volume create ps-printer-app
```

**Run the ps-printer-app Docker Container**

```sh
  sudo docker run -d \
      --name ps-printer-app \
      --network host \
      -e PORT=<port> \
      -v ps-printer-app:/var/lib/ps-printer-app \
      -v /dev/bus/usb:/dev/bus/usb:ro \
      --device-cgroup-rule='c 189:* rmw' \
      ps-printer-app:latest
```
- `PORT` is an optional environment variable used to start the printer-app on a specified port. If not provided, it will start on the default port 8000 or, if port 8000 is busy, on 8001 and so on.
- **The container must be started in `--network host` mode** to allow the Printer-Application instance inside the container to access and discover printers available in the local network where the host system is in.
- Alternatively using the internal network of the Docker instance (`-p <port>:8000` instead of `--network host -e PORT=<port>`) only gives access to local printers running on the host system itself.
- `-v ps-printer-app:/var/lib/ps-printer-app` maps a volume for persistent storage.
- The following volume and device settings are crucial for USB printer access:
  - `-v /dev/bus/usb:/dev/bus/usb:ro` mounts the host's USB device directory read-only inside the container for USB printer access.
  - `--device-cgroup-rule='c 189:* rmw'` allows the container to read, write, and mknod to USB devices.

#### Setting up

Enter the web interface:
```
http://localhost:<port>/
```
Use the web interface to add a printer. Supply a name, select the
discovered printer, then select automatic driver selection or choose a
make and model. Also set the installed accessories, loaded media and
the option defaults. Accessory configuration and option defaults can
also often get polled from the printer.

<!-- Begin Included Components -->
## Included Components
  - pappl v1.4.9
  - qpdf v11.10.1
  - ghostscript ghostpdl-10.05.1rc1_test002
  - cups v2.4.12
  - libcupsfilters 2.1.1
  - libppd 2.1.1
  - cups-filters 2.0.1
  - pyppd release-1-1-0
  - foomatic-db 20240504
  - hplip debian/3.22.10+dfsg0-8
<!-- End Included Components -->

## BUILDING WITHOUT PACKAGING OR INSTALLATION

You can also do a "quick-and-dirty" build without snapping and without
needing to install [PAPPL](https://www.msweet.org/pappl),
[cups-filters 2.x](https://github.com/OpenPrinting/cups-filters), and
[pappl-retrofit](https://github.com/OpenPrinting/pappl-retrofit) into
your system. You need a directory with the latest GIT snapshot of
PAPPL, the latest GIT snapshot of cups-filters, and the latest GIT
snapshot of pappl-retrofit (master branches of each). They all need to
be compiled (`./autogen.sh; ./configure; make`), installing not
needed. Also install the header files of all needed libraries
(installing "libcups2-dev" should do it).

In the directory with ps-printer-app.c run the command line

```
gcc -o ps-printer-app ps-printer-app.c $PAPPL_SRC/pappl/libpappl.a $CUPS_FILTERS_SRC/.libs/libppd.a $CUPS_FILTERS_SRC/.libs/libcupsfilters.a $PAPPL_RETROFIT_SRC/.libs/libpappl-retrofit.a -ldl -lpthread  -lppd -lcups -lavahi-common -lavahi-client -lgnutls -ljpeg -lpng16 -ltiff -lz -lm -lusb-1.0 -lpam -lqpdf -lstdc++ -I. -I$PAPPL_SRC/pappl -I$CUPS_FILTERS_SRC/ppd -I$CUPS_FILTERS_SRC/cupsfilters -I$PAPPL_RETROFIT_SRC/pappl/retrofit -L$CUPS_FILTERS_SRC/.libs/ -L$PAPPL_RETROFIT_SRC/.libs/
```

There is also a Makefile, but this needs PAPPL, cups-filters 2.x, and
pappl-retrofit to be installed into your system.

Run

```
./ps-printer-app --help
```

When running the non-snapped version, by default, PPD files are
searched for in

```
/usr/share/ppd/
/usr/lib/cups/driver/
/var/lib/ps-printer-app/ppd/
```

The last path is used when adding PPD files using the "Add PPD files"
page in the web interface.

You can set the `PPD_PATHS` environment variable to search other
places instead:

```
PPD_PATHS=/path/to/my/ppds:/my/second/place ./ps-printer-app server
```

Simply put a colon-separated list of any amount of paths into the
variable, always the last being used by the "Add PPD files"
page. Creating a wrapper script is recommended.

This Printer Application uses CUPS' backends and not PAPPL's, meaning
that for USB printers CUPS' USB quirk workarounds for compatibility
problems are used, network printers can also be used with IPP, IPPS,
and LPD protocols, and SNMP printer discovery is configurable.

USB Quirk rules in `/usr/share/cups/usb` and the `/etc/cups/snmp.conf`
file can get edited if needed.

Make sure you have CUPS (at least its backends) installed.

You also need Ghostscript to print PDF jobs.

For access to the test page `testpage.ps` use the TESTPAGE_DIR
environment variable:

```
TESTPAGE_DIR=`pwd` PPD_PATHS=/path/to/my/ppds:/my/second/place ./ps-printer-app server
```

or for your own creation of a test page (PostScript, PDF, PNG, JPEG,
Apple Raster, PWG Raster):

```
TESTPAGE=/path/to/my/testpage/my_testpage.ps PPD_PATHS=/path/to/my/ppds:/my/second/place ./ps-printer-app server
```

## LEGAL STUFF

The PostScript Printer Application is Copyright © 2020 by Till Kamppeter.

It is derived from the HP PCL Printer Application, a first working model of
a raster Printer Application using PAPPL. It is available here:

https://github.com/michaelrsweet/hp-printer-app

The HP PCL Printer Application is Copyright © 2019-2020 by Michael R Sweet.

This software is licensed under the Apache License Version 2.0 with an exception
to allow linking against GPL2/LGPL2 software (like older versions of CUPS).  See
the files "LICENSE" and "NOTICE" for more information.

### OCI image license label and bundled drivers

`elements/oci/ps-printer-app.bst` sets the OCI image label
`org.opencontainers.image.licenses=Apache-2.0`. This label describes **only the
ps-printer-app application source** in this repository (which is Apache-2.0).
It does **not** describe the third-party components bundled into the image:
HPLIP's `hpps` filter and PostScript PPD files, the Foomatic-db manufacturer
PostScript PPD files, and the shared printing base (CUPS, cups-filters,
Ghostscript, PAPPL and the rest). Those are licensed under their respective
upstream terms, several of them mixed or unresolved. The `just sbom` SPDX SBOM,
signed and attached on each push to `main` (publishing held by #45),
inventories the components and their pinned sources but carries no license
fields. The `Apache-2.0` label is intentionally left unchanged, as the application source
is genuinely Apache-2.0; the label's scope is the application source, not the
bundled components.

The license inventory, the pinned upstream sources, and the mixed-license and
unresolved files are documented in the `LICENSES` file.

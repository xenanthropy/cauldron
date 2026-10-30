# Cauldron — working notes

This file is the "start here" for anyone (human or Claude) picking Cauldron back
up. It records **what we're trying to achieve**, **how the code actually works**
(as of the 2025 tip of `master`), and **what is known to be broken**. The older
docs (`DESIGN`, `HACKING`, `API`, `ROADMAP`, `cauldron/PROCESS`,
`cauldron/TODO`) are still worth reading for intent, but they describe plans
more than reality; where they disagree with the code, trust the code and this
file.

---

## 1. Goal

Get Source Mage a working, modern install ISO again, so a tarball + manual
chroot is no longer the only way to install.

First target:

| Item        | Choice                                                         |
|-------------|----------------------------------------------------------------|
| Arch        | **x86_64** only                                                |
| Boot        | **BIOS + UEFI**, hybrid image (works burned to CD or `dd` to USB) |
| Grimoire    | **test** (no stable release since ~2011; everyone runs test)   |
| Contents    | Minimal live environment + `enchantment` installer + `system.tar.xz` |
| Stability   | Doesn't need to be "stable" — it needs to *build and boot*     |

Explicitly **not** goals right now: the `menu` installer, i18n, the "possess"
command, net installs.

**Init system (planned design, not started):** `simpleinit-msb` is deprecated
but is what all of cauldron's init handling targets, so the first ISO keeps it.
Afterwards, treat the *live ISO's* init and the *installed system's* init as
separate choices:
- live ISO: a `CAULDRON_ISO_INIT` setting with per-init setup functions. The
  initramfs (`etc/x86_64/initfs/init`) is already init-agnostic (it
  `switch_root`s to `/sbin/init`); the init-specific code is in
  `cauldron_etc_configs` (SMGL `init.d` `mountroot.sh`, `/etc/sysconfig/init`)
  and `cauldron_enchant_init` (`inittab`/agetty ttys running the installer).
- installed system: ship caches for several inits (`iso.install`) and let the
  enchantment installer ask which one to install, so one ISO serves all.
- providers in the test grimoire: `INIT` = simpleinit-msb, systemd, openrc
  (+ epoch, upstart); `INITSCRIPTS` = init.d, openrc. systemd works well;
  openrc is missing many service scripts (could be ported from Gentoo).

**Later / nice to have:** ISOs for other arches (32-bit x86, ppc) via the
cross-compile path (`toolchain cross`, `cauldron_toolchain_build_cross`).
Most config and data is already per-arch (`config/arch/*.conf`,
`etc/<arch>/`). Note: `cauldron_toolchain_build_cross` relies on
`sorcery rebuild`, which the team reports doesn't always work.

Other ideas for later:
- A menu installer (Lunar/Debian style: disk, partitioning, packages, network
  in dialog menus). Enchantment's steps (`enchantment/modules/`) are separate
  from the front end (`enchanters/`), so a `dialog` front end can drive the
  same steps; `enchanters/menu` is an old start.
- **Next after the first hardware install (decided Oct 2026):** a generic
  ISO kernel, based on a distribution's broad config (e.g. Void's
  `linux6.x` x86_64 dotconfig, which the maintainer has used on SMGL with
  everything working out of the box) plus `linux-iso.fragment` for the
  boot-critical built-ins; firmware selection needs a cap then (modinfo would
  pull in all GPU firmware). The x86_64 ISO doesn't have to fit a CD (USB is
  the norm on 64-bit machines); a CD-sized ISO matters more for a future
  32-bit x86 ISO, whose machines may not boot from USB.
- A graphical installer (e.g. Calamares) on a bigger "desktop" ISO: needs
  Qt, a display server, etc. in the live system; its own project.
- Hardware-tailored kernels: in the compile-kernel step, `make localmodconfig`
  (or `localyesconfig`) in the target's kernel sources keeps only the drivers
  the ISO kernel loaded for this machine. The broader the ISO kernel's module
  set, the better this works; review the result in `menuconfig` (devices not
  plugged in at install time are missed).

---

## 2. Repo map

| Path | What it is |
|------|------------|
| `cauldron/bin/cauldron` | The front-end command. Parses args, sources the config + libs, dispatches to `process_<command>` functions. Also an interactive REPL (`cauldron shell`, the default). |
| `cauldron/lib/libcauldron` | Main library: loads the other libs, and holds most of the sys/iso population, enchant, kernel and packaging functions. |
| `cauldron/lib/lib.chroot` | Mount/unmount + run-commands-in a chroot (reference counted). |
| `cauldron/lib/lib.sorcerous` | Talks to sorcery: download/install sorcery, set up grimoires, find spell caches, write sorcery config. |
| `cauldron/lib/lib.toolchain` | Getting the *build* chroot: unpack a basesystem tarball ("baseroot"), compiler test, kernel sources/headers. |
| `cauldron/lib/lib.init` | Builds the initramfs (busybox + modules + the `init` script). |
| `cauldron/lib/errorcodes` | `ERR_*` names + messages (registered via `liberror_add_error`). |
| `cauldron/config/*.conf` | Every tunable variable with its default. Start here when something uses the wrong path/version. |
| `cauldron/etc/` | *Data*: spell lists, kernel/busybox `.config`s, initramfs `init`, base `/etc` files, sorcery presets, grimoire patches. Per-arch under `etc/<arch>/`. |
| `enchantment/` | The installer that runs *on* the booted ISO (libs, step "modules", the `shell` enchanter). |
| `lib/` | `liberror`, `libcolor` — shared by cauldron and enchantment. |
| `local-exec/` | Wrapper + config to run cauldron straight from this git checkout (no install). **Use this.** |
| `ward/` | Old static checks (config vars, error codes, function names). |

---

## 3. Key concepts (no bash needed)

**Spells and caches.** Sorcery builds ("casts") spells from source. With
`ARCHIVE="on"` it also leaves a binary tarball of the result in
`/var/cache/sorcery/<spell>-<version>-<arch>.tar.xz`. *Those cache tarballs are
Cauldron's real build product.* Cauldron never copies files out of a live
system; it unpacks caches into fresh directories.

**Three working directories**, all under `CAULDRON_TMP` (default
`/tmp/cauldron`):

| Dir | Variable | Purpose |
|-----|----------|---------|
| `build/` | `CAULDRON_BUILD` | A complete SMGL system used as a **chroot** to cast everything. Starts as a basesystem tarball ("baseroot"). |
| `sys/` | `CAULDRON_SYS` | The **installable system**: caches from `sys.runtime` unpacked into an empty tree, then tarred to `system.tar.xz`. This is what gets put on the user's disk. |
| `isofs/` | `CAULDRON_ISO_SQUASHFS` | The **live environment** the ISO boots into (caches from `iso.runtime` + enchantment). Gets squashed into `isofs.img`. |
| `iso/` | `CAULDRON_ISO` | The **ISO9660 root**: kernel, initramfs, bootloader files, `isofs.img`. `mkisofs` turns this into the `.iso`. |

**Spell lists** are plain text files, one spell name per line (e.g.
`cauldron/etc/x86_64/sys/sys.runtime`). The config variable usually holds the
*path*; the code reads the file when it sees one.

**Build loop** (`build_spells` in `bin/cauldron`): skip spells that already have
a cache → `cast` the rest in the build chroot → `dispel` them again. The dispel
keeps `build/` lean; the caches stay behind.

**Boot flow of the finished ISO:** bootloader → kernel + `initfs.gz` → the
initramfs `init` (`cauldron/etc/x86_64/initfs/init`, busybox sh) finds the
CD/USB, loop-mounts `isofs.img`, puts a tmpfs **overlayfs** on top,
`switch_root`s into it → normal SMGL init → tty login runs
`enchantment welcome` (the installer), which installs `system.tar.xz` to disk.

---

## 4. How configuration is loaded

Running from git (`local-exec/cauldron.sh`):

```
local-exec/cauldron.sh
  sets CAULDRON_BASE=<repo>, CONFIG_FILE=local-exec/cauldron.conf, PATH+=cauldron/bin
  └─ cauldron/bin/cauldron
       source $CONFIG_FILE (local-exec/cauldron.conf)
         ├─ sets repo-relative paths (CAULDRON_CONF, CAULDRON_LIBS, CAULDRON_CONFIG=cauldron/etc, ...)
         ├─ source config/arch/x86_64.conf      (CAULDRON_ARCH, CAULDRON_SORCERY_ARCH)
         └─ source config/default.conf
              paths → security → display → iso → sys → sorcery → build
              → arch/host_arch (reads the HOST's /etc/sorcery/config!)
              → frontend → commands (last; builds CAULDRON_CMD_* arrays)
       source $CAULDRON_LIBS/libcauldron  (loads liberror, errorcodes, libcolor,
                                           lib.sorcerous, lib.chroot, lib.init, lib.toolchain)
       run_command "$@"  → process_<command>
```

Installed layout (`/etc/cauldron/cauldron.conf`, `/usr/share/smgl/...`) works
the same way; we don't use it yet.

**Overriding:** almost every default is written `: "${VAR:=value}"`, meaning
"set VAR only if nobody set it already". So any variable can be overridden by
exporting it in the environment, or by setting it in `local-exec/cauldron.conf`
*before* `default.conf` is sourced. Arrays use the equivalent
`[[ -n "$VAR" ]] || VAR=( ... )`.

**Every external command is an array** in `config/commands.conf`
(`CAULDRON_CMD_TAR`, `CAULDRON_CMD_MKISOFS`, `CAULDRON_CMD_CAST`, ...). Code calls
them as `"${CAULDRON_CMD_FOO[@]}" args`. Some contain the placeholder
`TARGETDIR`, substituted at call time with `${ARR[@]/TARGETDIR/$dir}`.

Inspect values with `cauldron config CAULDRON_ISO_SQUASH` (or no args for all).

---

## 5. Pipeline walkthrough

Commands map to `process_<name>` in `cauldron/bin/cauldron`. Each step can be
run on its own — that's how to debug.

### `brew` — everything
`process_toolchain` → `process_sys` → `process_iso` → `cleanse`.

### `toolchain [chroot|build|cross|prepare]` — make `build/`
- Tries each method in `CAULDRON_TOOLCHAIN_METHODS` (default only `chroot`).
- **`chroot`** → `cauldron_toolchain_baseroot` (`lib.toolchain`):
  `CAULDRON_BASEROOT` may be a directory (symlinked as `build/`), a tarball
  (unpacked), or a filename to download from `CAULDRON_BASEROOT_URL`. Then
  `cauldron_toolchain_baseroot_test` makes the FHS dirs and compiles + runs a
  tiny C program in the chroot.
- `build` / `cross` → **broken**, see §8.
- Always followed by **`cauldron_prepare`** (`libcauldron`):
  copy host `resolv.conf` → remove any sorcery in the chroot → download +
  install sorcery (`CAULDRON_SORCERY_URL`) → write grimoire list + download
  grimoire tarballs from `CAULDRON_SORCERY_GRIMOIRE_URL` → `scribe reindex` →
  `cauldron_sorcerous_cauldron_defaults` (writes `etc/sorcery/local/config` from
  `etc/toolchain/sorcery/config` + ARCHITECTURE/VOYEUR/MAKE_NJOBS, applies
  `etc/toolchain/grimoire_hacks/*/*.patch`, copies depends presets) → download
  kernel tarball, unpack to `build/usr/src`, copy in `CAULDRON_KERNEL_CONF`,
  `make headers_install`.

### `sys [build|populate|purify|package]` — make `system.tar.xz`
| Step | Function | Does |
|------|----------|------|
| build | `build_sys` → `build_spells $CAULDRON_SYS_SPELLS` | cast+dispel `etc/x86_64/sys/sys.runtime` in `build/` |
| populate | `cauldron_populate_sys` | mkdir FHS dirs in `sys/`, unpack each spell's cache, copy base `/etc` files, `ldconfig -r` |
| purify | `purify_sys` | run cleaner lists, fresh sorcery + grimoires installed into `sys/` |
| package | `cauldron_package_sys` | `tar` `sys/` → `xz` → `$CAULDRON_TMP/system.tar.xz` |

### `iso [build|populate|kernel|purify|ramfs|enchant|package|sorcery]`
| Step | Function | Does |
|------|----------|------|
| build | `build_iso` | cast+dispel `iso.runtime`, `iso.install`, `iso.package` lists |
| populate | `cauldron_iso_install_runtime`, `_caches`, `_sources` | unpack runtime caches into `isofs/` (+ gcc libs, busybox symlinks, copies `system.tar.xz` in); copy installable caches to `isofs/var/cache/sorcery`; `summon` sources into `isofs/usr/src` |
| kernel | `cauldron_iso_kernel` | `make` + `modules_install` in `build/usr/src/linux-<ver>`; copy `bzImage` to `iso/boot/kernel`, modules to `isofs/lib/modules` |
| purify | `purify_iso` | cleaner lists; optionally wipe sorcery from `isofs/` |
| ramfs | `cauldron_init_ramfs_make` + `_install` (`lib.init`) | build busybox with `etc/x86_64/busybox-<ver>.config`, copy bins/libs/modules (`initfs/modules` list), install `initfs/init`, cpio+gzip → `iso/boot/initfs.gz` |
| enchant | `cauldron_enchant` | copy enchantment (libs/config/modules/docs + enchanters) into `isofs/`, write version info, write `inittab`/`fstab`/login so ttys start the installer |
| package | `package_iso` | cast `iso.package` spells (syslinux, cdrtools, squashfs-tools), `mksquashfs isofs/ → isofs.img`, copy syslinux files, `mkisofs` → `$CAULDRON_TMP/smgl-devel-YYYYMMDD.x86_64.iso` |

### Helpers
`chroot [-d DIR] [CMD]` (shell inside `build/` with mounts handled), `config`,
`cleanse` (**deletes all of `/tmp/cauldron`**), `help`, `shell`, `version`.

---

## 6. Bash crash course (only what this code uses)

| Idiom | Meaning |
|-------|---------|
| `"${arr[@]}"` | all elements of an array, each kept as one word. `$arr` alone = first element only (the code relies on this in places). |
| `: "${X:=val}"` | assign default if X unset/empty. `:` is a no-op command. |
| `${v#pre}` / `${v##*/}` | strip shortest prefix / longest prefix up to last `/` (= basename). |
| `${v%suf}` / `${v%/*}` | strip suffix / everything after last `/` (= dirname). |
| `${arr[@]/TARGETDIR/$d}` | substitute in every element. |
| `[[ -f "$s" ]] && s=( $(< "$s") )` | "if this is a file, replace it with the file's words" — how spell-list paths become arrays. |
| `cmd \|\| return $ERR_X` | on failure, return an error code. |
| `liberror_check \|\| return $?` | if the previous command failed, print its error message and pass the code up. With one arg the arg is extra info; with two, the first overrides the code. |
| `check_fatal` (bin/cauldron) | on error: unmount all chroots (`cauldron_chroot_cleanup`) then exit via `liberror_die`. |
| `cauldron_chroot_init DIR` … `cauldron_chroot_done DIR` | always paired. Init bind-mounts `dev`, `dev/pts`, mounts `proc`, `sys`, `run`; nested inits of the same dir just bump a counter; the last `done` unmounts. |
| `cauldron_chroot CMD...` | run CMD inside the *current* chroot (`-q` quiet, `-s` silence stdout). |
| `function foo() { local x="$1"; ... }` | functions take positional args; `local` scopes vars. |

Return codes: `0` = `$ERR_OK`; everything else is an `ERR_*` registered in
`cauldron/lib/errorcodes` (cauldron) or `enchantment/lib/errorcodes`.

---

## 7. Running it (tarball-chroot workflow)

Cauldron needs **root** and an **SMGL environment** around it
(`config/arch/host_arch.conf` reads the host's `/etc/sorcery/config`, and
`cauldron_prepare` copies the host `resolv.conf`). A real SMGL install is not
required — an unpacked SMGL tarball on any distro works:

Known-good inputs (Oct 2026; `download.sourcemage.org` and `codex.sourcemage.org`
redirect to `mirror.sobukus.de/files/sourcemage/`, which also serves HTTPS):

| What | URL |
|------|-----|
| Basesystem tarball (+ `.sha512`, `.sig`) | `https://mirror.sobukus.de/files/sourcemage/image/official/test/smgl-test-0.63-20251212_1200-basesystem-x86_64.tar.xz` |
| Sorcery tarballs (last built 2024; devs mostly install sorcery from git: `https://github.com/sourcemage/sorcery`, `make install`) | `https://mirror.sobukus.de/files/sourcemage/sorcery/sorcery-test.tar.bz2` |
| Grimoires (+ `.asc`) | `https://mirror.sobukus.de/files/sourcemage/codex/test.tar.bz2` |

The tarball's `.sig` is made with key `4746 AECF 3E0B 39BE F7C2 12ED 4782 40C4
FA5A 74CE` (Remko van der Vossen); it is not on public keyservers but ships in
`/usr/share/smgl-pubkeys/*.gpg`. Verify with
`gpgv --keyring <tarball>/usr/share/smgl-pubkeys/sorcery-stable.gpg x.sig x.tar.xz`.

```sh
# on the outer (any) Linux host, as root
mkdir -p /srv/smgl && tar -xpf smgl-test-0.63-20251212_1200-basesystem-x86_64.tar.xz -C /srv/smgl
for d in dev dev/pts proc sys; do mount --rbind /$d /srv/smgl/$d; done
cp /etc/resolv.conf /srv/smgl/etc/
chroot /srv/smgl /bin/bash -l

# inside the SMGL chroot
git clone <this repo> /root/cauldron && cd /root/cauldron
./local-exec/cauldron.sh            # opens the cauldron REPL; or:
./local-exec/cauldron.sh help
CAULDRON_BASEROOT=/path/to/smgl-<current>-x86_64.tar.xz ./local-exec/cauldron.sh toolchain
./local-exec/cauldron.sh chroot     # poke around inside build/
```

Tips:
- The defaults are current: `test` grimoire, sorcery from git master (GitHub
  archive tarball, no git needed), HTTPS mirror URLs, kernel 6.18.59, and the
  smgl-test-0.63-20251212 baseroot (downloaded from the mirror if not present
  locally). Pointing `CAULDRON_BASEROOT` at a **local** tarball (or an already
  unpacked directory) saves the download. A tarball produced by `cauldron sys`
  works as a baseroot too (verified Oct 2026). To re-run `toolchain` without
  re-unpacking, use `CAULDRON_BASEROOT=/tmp/cauldron/build` (a directory equal
  to `CAULDRON_BUILD` is used as-is).
- For local overrides, put them in a small config file that sets them and then
  sources `local-exec/cauldron.conf`, and run
  `cauldron/bin/cauldron -f that.conf <command>` (with `CAULDRON_BASE` set to
  the repo). Example:
  ```sh
  : "${CAULDRON_BASEROOT:=/root/smgl-test-0.63-20251212_1200-basesystem-x86_64.tar.xz}"
  : "${CAULDRON_SORCERY_COMMIT:=39a44962...}"   # optional: pin sorcery
  : "${CAULDRON_BUILD_JOBS:=8}"
  source /root/cauldron/local-exec/cauldron.conf
  ```
- Run steps one at a time (`toolchain`, then `sys build`, then `sys populate`, ...).
- If a run dies with things still mounted: `grep /tmp/cauldron /proc/mounts`
  and `umount -R` them (deepest first) before deleting anything. **Never
  `rm -rf /tmp/cauldron` with mounts still active** — bind-mounted `/dev` would
  get wiped.
- Boot-test results in QEMU: `-cdrom x.iso` (SeaBIOS) and with
  `-bios /usr/share/ovmf/OVMF.fd` (UEFI).

---

## 8. Known breakage

From reading the code (Oct 2026). **[confirmed]** = verified by reading the
code/history; **[suspected]** = needs a real run to confirm.

### Report for the team (outside cauldron)
Findings for the grimoire, sorcery and tarball maintainers; details in the
sections below.
- **Grimoire**
  - busybox no longer builds with its defaults: libtirpc has been built with
    `--disable-static` since 2025-12-01, but busybox's default config is
    static and its BUILD always links `-ltirpc` (cauldron now builds busybox
    dynamically). Fix: static libtirpc again, or busybox dynamic / without
    forced tirpc.
  - `smgl-base` + `smgl-system` don't pull in `shadow` (no login/passwd) or
    `lzip` (and the old tarballs also had `kbd`, `man-pages`).
  - `optional_depends gdbm '' '' ...` pattern (python3, perl, ...): a
    disabled dependency passes no `--without`, so the library is linked
    anyway and sorcery's records are wrong.
  - e2fsprogs doesn't declare fuse, but configure finds it and builds
    `fuse2fs` linked to `libfuse.so.2` (should be an `optional_depends fuse`
    with `--disable-fuse2fs`). The ISO lists fuse explicitly for now.
  - Dead or broken source URLs: `isl` (gforge), `fallback.sourcemage.org`
    certificate, `david.kow.is`.
  - parted 3.6 and squashfs-tools 4.4 don't build with gcc 16 (incompatible
    pointer types, an error since gcc 14: `command_create` in parted.c,
    `signal` handlers in mksquashfs.c). Cauldron works around it with
    `etc/toolchain/grimoire_hacks/` (adds
    `-Wno-error=incompatible-pointer-types`); better fixes: squashfs-tools
    4.6+ (4.4 is from 2020), upstream patches for parted.
  - git (2.56.0) now `depends rust`, so casting git means compiling rust and
    llvm; git is therefore not offered on the ISO for now. Worth deciding
    whether rust/llvm caches should be provided (also useful for other
    spells moving to rust).
  - rsync DETAILS: `UPSTRAM_HASH` typo.
  - grub2's `grub-default` sets `GRUB_DISABLE_UUID=true`, a variable GRUB
    doesn't know (it's `GRUB_DISABLE_LINUX_UUID`). `grub-mkconfig` then
    writes `root=UUID=...` whenever `/dev/disk/by-uuid` exists, which only
    works with an initramfs; SMGL kernels boot without one, so the
    installed system panics. Fix: `GRUB_DISABLE_LINUX_UUID=true` +
    `GRUB_DISABLE_LINUX_PARTUUID=false` (`root=PARTUUID=` is handled by
    the kernel itself). Cauldron patches it (`grimoire_hacks/grub2`) and
    the installer's grub step tells the user to check it.
  - wpa_supplicant 2.11 doesn't build against OpenSSL 4 (`ASN1_STRING` is
    opaque now; `tls_openssl.c` uses `->data`/`->length`). Cauldron patches
    it (`grimoire_hacks/wpa_supplicant`); other distributions carry the same
    accessor fix.
  - wireless-regdb only installs the CRDA file (`/usr/lib/crda/
    regulatory.bin`); kernels since 4.15 load `/lib/firmware/regulatory.db`
    (+ `.p7s`), so without it wifi stays in the restrictive world regulatory
    domain ("failed to load regulatory.db" at boot). Cauldron patches the
    INSTALL (`grimoire_hacks/wireless-regdb`).
  - eudev's rules use the groups `render` and `sgx`, which SMGL's
    `/etc/group` (smgl-base / init.d) doesn't have ("specified group
    'render' unknown" at boot), so render nodes fall back to root.
  - grub2 builds one platform per cast (`i386-pc` *or* `x86_64-efi`); a
    cache for a hybrid ISO / installer has to be assembled from two casts
    (cauldron does this in `cauldron_iso_grub_cache`). A spell option to
    build several platforms would be simpler.
  - Defaults worth reviewing: python3 builds without readline and sqlite
    unless asked; nghttp2's python bindings default on when python3 is
    installed (pulls boost + openmpi).
- **Security: SSH host keys are shipped** (found Oct 2026):
  - the official basesystem tarball (smgl-test-0.63-20251212) contains
    `/etc/ssh/ssh_host_{dsa,ecdsa,ed25519,rsa,}_key` from 2015–2017: every
    system installed from it shares those private keys until someone
    regenerates them (`rm /etc/ssh/ssh_host_*; ssh-keygen -A`). Rebuild the
    tarball without them, and tell users.
  - the openssh spell's `make install` runs `ssh-keygen -A` on the casting
    machine, so a cache (cauldron's, or anyone's `ARCHIVE=on` cache shared
    with others) carries that machine's keys; it also leaves out
    `ssh_config`/`sshd_config` when they already exist. The init.d script
    never generates keys. Cauldron's fix: `grimoire_hacks/openssh`; and
    `cauldron_iso_check` refuses an ISO with host keys in the live system or
    in any of its caches.
- **Installer text**: the welcome screen
  (`enchantment/modules/welcome/instructions`) still points to
  `#sourcemage-cauldron` on irc.freenode.net; update it to wherever the
  channel lives now.
- **sorcery**
  - `update_sorcery_scripts` casts `basesystem`, which conflicts with
    `smgl-base` (`sorcery update` tries to replace smgl-base/smgl-system).
  - The default sustained list still names `module-init-tools`.
- **Basesystem tarball**: see "If a new baseroot tarball is ever made"
  (module-init-tools, basesystem, stale 3.4.51 modules, no caches, how it was
  built).

### Status / fixed so far
- **Stage one done (Oct 2026): `toolchain` + `sys` produce a release
  basesystem tarball.** Against the smgl-test-0.63-20251212 tarball + test
  grimoire + sorcery git master, `cauldron sys` writes `system.tar.xz` plus a
  release-named hardlink `smgl-test-0.63-<YYYYmmdd_HHMM>-basesystem-x86_64.tar.xz`
  and `.sha512` (optional `.sig` with `CAULDRON_SYS_SIGN_KEY`): ~313 MiB
  compressed, 1.9 GB unpacked, 104 spells (`smgl-base` + `smgl-system` + the
  extras in `sys.runtime` + dependency closure; gcc 16, glibc 2.44, openssl
  4.1.0, python 3.14, kmod, gnupg 2.4, simpleinit-msb). The official 2025-12
  tarball is 361 MiB / 95 spells. `purify` ends with `cauldron_sys_check`
  (essential binaries, unresolved libraries, sorcery records, gpg, wget
  https). Smoke-tested in a fresh chroot: init, login/passwd/useradd/su,
  loadkeys, man, wget https, sorcery, trimmed locales, python ssl + dbm.
- **Validated as a baseroot:** a fresh run with the new tarball as
  `CAULDRON_BASEROOT` (empty `CAULDRON_TMP`) passes `toolchain` (nothing
  obsolete to remove) and the whole `sys` stage, and re-produces a 104-spell
  tarball whose `.sha512` verifies. Caches were reused from the first run, so
  that run checked the pipeline, not a from-scratch compile.
- **Stage two (Oct 2026): `cauldron iso` produces a hybrid x86_64 ISO**
  (`smgl-devel-YYYYMMDD.x86_64.iso` + `.sha512`, ~600 MiB: fits an 80-min CD). What it is:
  - live system = `iso.runtime` + its dependency closure, minus build-only
    spells (`CAULDRON_ISO_RUNTIME_EXCLUDE`) plus gcc's runtime libraries;
    squashfs (xz, 1 MiB blocks); `system.tar.xz` inside, caches of
    `iso.install` (grub2 for BIOS+UEFI, efibootmgr, dosfstools, mdadm, lvm,
    cryptsetup-luks, xfsprogs, btrfs-progs, openssh) in `/var/cache/sorcery`; no kernel sources by default (see below)
  - kernel 6.18.59 (`x86_64_defconfig` + `etc/x86_64/linux-iso.fragment`:
    the drivers needed to reach the boot medium are built in, the rest are
    modules), initramfs with a dynamically linked busybox 1.37
  - GRUB 2.12 for both `i386-pc` and `x86_64-efi`, `xorriso` image with El
    Torito BIOS + EFI entries, an MBR for USB sticks and an appended EFI
    system partition
  - Boot matrix in QEMU (SeaBIOS / OVMF, TCG): BIOS CD, UEFI CD, BIOS USB
    stick, UEFI USB stick all reach the installer on tty1. Not yet tried on
    real hardware.
  - USB sticks must be written as a raw image (`dd`, Etcher, Rufus in "DD
    image" mode). Rufus' "ISO image" mode and Ventoy don't work: the
    initramfs looks for an ISO9660 filesystem holding `isofs.img` on the
    block devices (`scan_cdrom` in `initfs/init`). Supporting them would mean
    also searching FAT/ext filesystems for `isofs.img` (and, for Ventoy, an
    ISO file).
  - Secure Boot isn't supported (GRUB is unsigned; no shim).
  - First real hardware (Chuwi MiniBook X, UEFI, USB stick through a USB-C
    adapter, Oct 2026): boots, but showed what QEMU couldn't:
    - the stick appeared after the initramfs had scanned for the boot device
      once, so it fell through to its menu (choosing "scan" there worked).
      The initramfs now scans repeatedly (`SMGL_SCAN_TRIES`/`SMGL_SCAN_WAIT`
      in `initfs/init`, `bootscan=N` on the kernel command line); tested in
      QEMU by plugging the stick in 10 s after the kernel started.
    - the panel is mounted sideways. The kernel console now has
      `CONFIG_FRAMEBUFFER_CONSOLE_ROTATION` (follows the orientation the GPU
      driver reports; `fbcon=rotate:1`/`:3` overrides it, verified in QEMU
      under UEFI). The MiniBook X isn't in the kernel's
      `drm_panel_orientation_quirks` table as of 6.18. GRUB 2.12 can't
      rotate, so its menu stays sideways.
    - GRUB prints "serial port 'com0' isn't found" on machines without a
      serial port: harmless (the ISO's `grub.cfg` offers its menu on the
      serial port too, which the QEMU tests rely on).
    - `/proc/sys/kernel/hotplug` doesn't exist without
      `CONFIG_UEVENT_HELPER`; the initramfs no longer depends on it.
    - From its `dmesg`/`lspci -nnk` (hardware: Alder Lake-N, Intel AX101
      CNVi wifi `8086:54f0`, BT `8087:0026`, NVMe, DSI panel):
      - built-in i915 probed before `/lib/firmware` existed, found no
        GuC/DMC firmware and declared the GPU wedged. i915 is a module now
        (simpledrm shows the console until it loads), firmware comes from
        the live system (`cauldron_iso_firmware`).
      - its firmware doesn't report the sideways panel (nothing in the
        kernel's quirk table either), so `grub.cfg` matches the DMI product
        name ("MiniBook X") and adds `fbcon=rotate:1
        video=DSI-1:panel_orientation=right_side_up` (`smgl_quirks`).
        Better long term: a `drm_panel_orientation_quirks` entry upstream.
        Only machines matched there get these options; add others the same
        way. It also gets `fbcon=font:TER16x32`: the kernel only picks its
        16x32 font by itself when the 8x16 one would give more than ~20000
        character cells (`get_default_font`, ~2560x1440 and up), and this
        1920x1200 10" panel stays just below.
      - no drivers for the LPSS I2C/SPI controllers (touchpad behind
        I2C-HID, touchscreen, MXC6655 accelerometer) or the SD reader:
        added to the fragment (with GPIOLIB/PINCTRL, which defconfig lacks).
      - audio: "snd_hda_intel: Cannot probe codecs" — this model needs the
        SOF DSP driver plus SOF firmware (not in linux-firmware); not done.
      - udev: "specified group 'render' unknown" (also 'sgx'): SMGL's
        `/etc/group` lacks these groups (for the team).
      - old CPU microcode (0x0e); no early microcode loading on the ISO.
      - confirmed on the hardware with the 20261030 ISO: the DMI match in
        `grub.cfg` rotates the console and selects the 16x32 font without
        any typing, the stick is found automatically, and wifi works (AX101
        with the selected iwlwifi firmware, wpa_supplicant + dhcpcd).
        sshd on that ISO needed `-f /dev/null` (no sshd_config: the openssh
        spell bug, fixed since by `grimoire_hacks/openssh`).
        dmesg: iwlwifi loaded `so-a0-hr-b0-89.ucode` (the newest the 6.18
        driver supports, picked by `cauldron_iso_firmware`); i915 loaded
        DMC, GuC and HuC firmware ("GUC: submission enabled", no longer
        wedged). Harmless: "[drm] *ERROR* DSI link not ready" (common on
        Alder Lake-N DSI panels). udev renames wlan0 to wlp0s20f3.
      - cfg80211 is built in, so it still logs "failed to load
        regulatory.db" at boot (before the live system is mounted); it
        loads the file when a wifi device first asks for its regulatory
        domain. Making cfg80211/mac80211 modules would silence it.
  - Install walkthrough in QEMU, BIOS (MBR disk) and UEFI (GPT + EFI system
    partition), every installer step in order on a serial console: partition
    → format → mount → select caches (grub2, efibootmgr, efivar, dosfstools)
    → `install basesystem` → `install caches` → spell options → fstab →
    `install iso-kernel` → grub-install + grub-mkconfig → root password.
    Both installed systems boot (GRUB → kernel 6.18.59 with
    `root=PARTUUID=...`, no initramfs) to a login prompt, with 110 spells
    known to sorcery. (For the test the installed system got a serial
    console added by hand: kernel `console=ttyS0`, a ttyS0 getty.)
  - Installer bugs found and fixed by that walkthrough: `enchantment next`
    (`libcheck_error`); spell names read from cache labels (`cast 0 0 0`);
    leaving any chroot unmounted the target itself; `install iso-kernel`
    (`local $src`, dangling `/boot/kernel` link, modules copied to
    `lib/modules/modules/...`, wrong `depmod -b`); `install caches` waited
    150 s at every sorcery question and answered optional dependencies
    "no" although the cached binaries link them (grub-install failed on
    `libdevmapper`): it now passes each cache's recorded answers to sorcery
    and adds the caches of missing dependencies (here lvm, libaio).
  - Found on the hardware: the short installer commands (`next`, `list`,
    `install`, ... from `enchanters/shell/aliases`) didn't exist in the
    login shell: `bashrc` only sourced the aliases when `ENCHANT_ENCHANTERS`
    was set, which it never is there. The QEMU walkthroughs typed
    `enchantment next` and missed it. `bashrc` now falls back to the default
    path. Workaround on older ISOs:
    `source /usr/share/smgl/enchantment/enchanters/shell/aliases`.
  - Seen at boot of the installed system, not investigated: lvm's boot
    script prints "File locking initialisation failed." twice.
  - Under QEMU without KVM, `install caches` takes ~10 minutes (sorcery's
    dependency resolution); on hardware it should be far quicker.
  - Kernel sources are left off the ISO by default (~150 MB; with them the
    ISO is ~750 MiB, too big for a CD): `CAULDRON_ISO_KERNEL_SOURCES=yes`
    puts them back. The installer's `enchantment install kernel-source`
    copies them from the ISO if present, else downloads them from
    kernel.org, and unpacks them with the ISO kernel's config as `.config`.
- **Workarounds still in place** (each should become a proper fix):
  - `etc/toolchain/grimoire_hacks/{parted,squashfs-tools,grub2,
    wireless-regdb,wpa_supplicant,openssh}` (see the
    README there and the team report above)
  - `etc/toolchain/sorcery/default_depends`: nghttp2 without python/boost
  - `iso.runtime` lists `fuse` (undeclared e2fsprogs dependency); `iso.install`
    leaves out git (rust)
  - busybox is linked dynamically and its libraries copied into the
    initramfs (static libtirpc missing)
  - the installer's grub step tells the user to fix `/etc/default/grub` by
    hand for caches built before the grub2 hack.
- Known leftover: sorcery keeps the old `libssl.so.3`/`libcrypto.so.3` across
  the openssl 3→4 upgrade and records them in the openssl 4.1.0 cache, so
  they ship in `system.tar.xz` (unused once everything is rebuilt).
- Fixed on the working branch (see `git log` for details on each):
  `cauldron config` with several args; log truncation in `cauldron_chroot`
  (`&> /dev/stdout`); host arch detection (`host_arch.conf` yielded `i386`);
  `run` in `CAULDRON_FHS_DIRS`; `$state` in `cauldron_sorcerous_spell_cache`
  (and chroot messages leaking into its returned path); grimoire refresh path;
  obsolete 2015 glibc grimoire patch and dead presets removed;
  `cauldron_etc_configs` accepts `sys`/`iso`; `build_spells` only dispels spells
  the build chroot didn't already have and verifies every spell produced a
  cache; `cauldron_prepare` keeps sorcery's installed-spell records
  (`keepstate`); obsolete spells removed from the build chroot
  (`CAULDRON_SORCERY_OBSOLETE`); `cauldron_chroot_dispel` skips uninstalled /
  sustained spells; cauldron waits for background casts before unmounting and
  copes with stacked mounts; `sys.runtime` uses `gnupg-2.4`/`procps-ng`;
  `sys` covers the dependency closure; sorcery state regenerated from tablets.

### How cauldron interacts with the baseroot tarball / sorcery
Things learned the hard way; keep them in mind when changing the build code.
- **`build/` *is* the baseroot.** `toolchain` unpacks the tarball there and
  reinstalls sorcery, but must keep `/var/state/sorcery` + `/var/log/sorcery`
  (the record of what the tarball has installed). Without them sorcery thinks
  nothing is installed and rebuilds every dependency.
- **The tarball ships no caches**, so every spell cauldron needs is compiled,
  even if the tarball already has it installed (casting an installed spell
  recasts it to produce the cache). `build_spells` skips spells whose cache
  already exists, so interrupted runs resume where they stopped.
- **The tarball lags the grimoire.** Expect upgrades during `sys build`
  (here: gcc 15→16, glibc 2.42→2.44, openssl 3.5→4.1, python 3.13→3.14), and
  replaced spells: module-init-tools→kmod (sustained in the tarball, and kmod's
  CONFLICTS defaults to "no", so cauldron dispels it up front),
  procps→procps-ng, gnupg (now a placeholder)→gnupg-2.4, basesystem→smgl-base
  + smgl-system.
- **Library upgrades mid-build leave stale caches.** A cache built before a
  library upgrade still links the old soname (e.g. `libssl.so.3` after openssl
  4). The old library stays in `build/`, so nothing breaks there, but
  `system.tar.xz` only contains the new one. After such an upgrade, find
  binaries still linking the old soname (`readelf -d ... | grep NEEDED`) and
  recompile their spells with `cast -c` (plain `cast` just resurrects the
  stale cache). Found this way: coreutils, python3.
- **sorcery's exit codes are not trustworthy for cauldron's purposes:** `cast`
  can return 0 when spells were skipped (e.g. a dependency's download failed),
  and can return early after reporting a conflict while already-started casts
  continue in the background (python3's triggers also recast dependents in the
  background). Cauldron therefore checks for caches itself and waits for
  background casts before unmounting.
- **sys = closure, not list.** `sys.runtime` is the curated top level;
  cauldron adds every enabled dependency (`cauldron_sorcerous_depends_closure`)
  so the installed system isn't missing runtime libraries (libxcrypt for
  login, gnupg's libs, zstd for kmod, ...).
- **Unpacked caches aren't "installed" to sorcery** until
  `cauldron_sorcerous_state_from_tablets` rebuilds `packages`/`depends` from
  the tablet pages each cache carries.
- To change a spell option unattended, edit
  `build/etc/sorcery/local/depends/<spell>.p` before casting.
- **Optional dependencies default to "yes" when the dependency is installed in
  `build/`** (e.g. python3), which drags in a lot (nghttp2's python bindings
  pulled boost + openmpi into the ISO build). Cauldron's answers go in
  `etc/toolchain/sorcery/default_depends` (installed as sorcery's
  `/var/state/sorcery/default_depends`, format `spell:dependency:on|off`).
  Recorded answers win over that file: sorcery's `depends` database, and the
  answers of interrupted casts in `/var/state/sorcery/abandoned/<spell>`
  (moved there at the next cast from `.../uncommitted/`). After killing a
  cast, delete the affected spells' files in *both* directories, or the
  old answers come back.
- When stopping a cauldron run by hand, kill by PID (`ps -eo pid,args`);
  `pkill -f <script>` also matches the shell running the pkill. Then unmount
  what's left under `build/` (deepest first) before restarting.

### Found while running it
- **[confirmed]** The 2025-12 basesystem tarball ships no spell caches
  (`/var/cache/sorcery` is empty), so `sys build` compiles every spell from
  source, gcc and glibc included.
- **[confirmed]** The tarball still carries kernel modules for 3.4.51 in
  `/lib/modules`.
- **[confirmed]** The tarball has `basesystem` installed. Since 2020 the
  grimoire splits it into `smgl-base` + `smgl-system`; `basesystem` and
  `smgl-base` `conflicts` each other, and no other spell depends on
  `basesystem` any more. `sys.runtime` lists individual spells rather than
  either meta-spell.
- **[fixed]** `cauldron_prepare` wiped `/var/state/sorcery` in the build
  chroot, so sorcery forgot the whole baseroot (recompiling every dependency,
  and `build_spells` then dispelled perl/xz-utils/... from `build/`). It now
  keeps the installed-spell records (`cauldron_sorcerous_clean ... keepstate`).
- **[confirmed]** Grimoire source URLs broken for everyone (as of Oct 2026),
  worth reporting to grimoire maintainers: `isl` (`isl.gforge.inria.fr` is
  dead; `https://sourceforge.net/projects/libisl/files/` works);
  `fallback.sourcemage.org` presents a certificate that doesn't match its name
  over HTTPS; `david.kow.is/sourcemage/` 404s for everything tried.
- **Agent sandbox note** (only relevant when running cauldron inside a Claude
  Code cloud sandbox): only HTTPS egress is allowed, so plain `http://`/`ftp://`
  spell sources fail. Workaround used there: a wrapper at
  `build/usr/sbin/wget` rewriting URLs to `https://`, plus pre-fetching a few
  sources into `build/var/spool/sorcery`. Not needed on a normal machine.
- **[fixed]** (`cauldron_sorcerous_state_from_tablets`) `cauldron_populate_sys` only unpacks caches into `sys/`; it
  never registers them with sorcery (`/var/state/sorcery/packages`, install
  logs), and `purify_sys` then installs a fresh sorcery. The installed system
  may therefore not know what's installed. Likely fix: resurrect the caches
  with sorcery inside the `sys/` chroot instead of raw `tar -x`.

### Will fail outright / missing pieces
- **[confirmed] Toolchain `build`/`cross` call deleted functions.**
  `cauldron/bin/cauldron:220-234` calls `cauldron_toolchain_cache_make`,
  `cauldron_toolchain_build_host` and `cauldron_toolchain_cross`. These are
  *not* sorcery functions — the first two were cauldron's own and were removed
  in the lib.toolchain refactor `f7f312f` (2018-02-11), replaced by
  `cauldron_toolchain_cache_cast`, `cauldron_toolchain_build` and
  `cauldron_toolchain_build_cross`. The front-end rewrite the next day
  (`2861564`) kept the old names; `cauldron_toolchain_cross` never existed. Only
  the `chroot` (baseroot) method is wired up — which is the default and the one
  we want anyway.
- **[confirmed]** `process_enchant` (`bin/cauldron:1047`) calls an `enchant`
  function that has never existed. `cauldron iso enchant` (→ `enchant_iso`) is
  the working path.
- **[fixed]** (`cauldron/data/cleaners/{sys,iso}` added) `CAULDRON_DATA` = `cauldron/data/` didn't exist, so the
  cleaner lists `cleaners/sys/*` and `cleaners/iso/*` used by `purify_sys` /
  `purify_iso` are missing (the glob stays literal, `sort` complains, and
  nothing is cleaned — silently "succeeds").
- **[fixed]** (`etc/x86_64/iso/` added) `config/iso.conf` and `config/sys.conf` expect
  `etc/x86_64/iso/{iso.runtime,iso.install,iso.sources,iso.package}` and
  `etc/x86_64/sys/{sys.runtime,sys.install,sys.sources}`. Only
  `etc/x86_64/sys/` exists (`sys.install` and `sys.sources` are empty). There is
  **no `etc/x86_64/iso/` at all**; the only ISO lists are the older flat
  `etc/x86/iso.spells`, `iso.caches`, `iso.sources`.
- **[fixed]** (GRUB replaces syslinux: `etc/x86_64/iso/grub.cfg`) `libcauldron` also reads these non-existent files from
  `etc/x86_64/iso/`: `fstab`, `inittab`, `login.sh` (`cauldron_enchant_init`),
  `syslinux.cfg` (+ optional `syslinux.msg`, `installsmgl.img`)
  (`cauldron_iso_bootloader`).
- **[fixed]** `cauldron_etc_configs` (`libcauldron:265`) only accepts
  target types `bootable` or `chroot` and returns `ERR_TARGET` otherwise, but is
  called with `'sys'` (`libcauldron:416`) and `'iso'` (`libcauldron:529`) — so
  `sys populate` and `iso populate` fail after copying the files.
- **[fixed]** `cauldron_sorcerous_spell_cache` (`lib.sorcerous:388`) greps
  `"$state"`, which is never set (should be `$CAULDRON_BUILD/var/state/sorcery/packages`).
  It then falls back to `gaze`, so this may "work" slowly/noisily.
- **[fixed]** `cauldron_add_enchanters` (`libcauldron:1007`) uses an
  undefined `$data` (lines 1018–1027) and copies from
  `$CAULDRON_ENCHANT_DIR/<enchanter>`, but enchanters live in
  `enchantment/enchanters/<enchanter>`.
- **[fixed]** `cauldron_enchant` writes `welcome/editors` to
  `$ENCHANT_MODULES` on the **host**, not under the target
  (`libcauldron:1177,1181`), and line 1181 has a stray `\ ` after `column -t -s:`.

### Stale versions / URLs
- **[fixed]** Kernel (now 6.18.59), busybox (1.37.0) and baseroot (now
  smgl-test-0.63-20251212) defaults in `config/build.conf`, all over HTTPS.
  The 6.18 kernel config is `x86_64_defconfig` + `etc/x86_64/linux-iso.fragment`;
  busybox for the initramfs is 1.37 (the grimoire's version,
  `CAULDRON_SYSUTILS_VERS`). The gcc/musl/binutils/... settings remain stale
  but only feed the unused from-scratch toolchain path (marked as such).
- **[fixed]** Grimoire/sorcery default to `test`; sorcery comes from git
  master (`CAULDRON_SORCERY_SOURCE=archive|git|tarball`).
- **[fixed]** Sorcery/grimoire/baseroot URLs point at `mirror.sobukus.de`
  over HTTPS (the old `download.`/`codex.sourcemage.org` paths redirect there;
  the `smgl-stable-0.61` baseroot is gone).
- **[fixed]** `config/arch/host_arch.conf` greps `ARCHITECTURE=` from the
  host's main sorcery config; on current sorcery it may live elsewhere
  (local config), leaving `CAULDRON_HOST_ARCH` empty.

### Logic bugs / modernisation
- **[fixed]** `cauldron_chroot_init` mounts tmpfs on `$target/run`
  (`lib.chroot:87`) but `run` is not in `CAULDRON_FHS_DIRS`; fails if the
  baseroot lacks `/run`.
- **[confirmed]** `cauldron_fs_bootstrap` runs `/sbin/MAKEDEV`
  (`libcauldron:239`) — obsolete; devtmpfs does this now. (Not called by the
  main pipeline.)
- **[fixed]** `cauldron_sorcerous_update_grimoires` removes
  `"$target/$codex/$grimoire"` *inside* the chroot (`lib.sorcerous:336`) — wrong
  path, so stale grimoires aren't removed.
- **[confirmed]** `cauldron_toolchain_kernel_source` never downloads the
  signature and checks the same `$?` twice (`lib.toolchain:251-259`).
- **[confirmed]** `cauldron_init_fs_init` uses `"${CAULDRON_CMD_CHMOD}"`
  without `[@]` (`lib.init:324`) — works only because the array has one element.
- **[fixed]** (GRUB + xorriso hybrid, see Status) Packaging was BIOS-only: `CAULDRON_CMD_MKISOFS`
  (`config/commands.conf:41`) uses isolinux El Torito flags;
  `CAULDRON_ISO_BOOTENV=efi` is half-implemented and the `grub` bootloader
  branch is empty. UEFI + USB needs `xorriso` with an EFI system partition image
  and a hybrid MBR/GPT.
- **[suspected]** `cauldron_chroot_init` only updates `CAULDRON_CHROOT` (the
  active chroot command) when it's the first chroot or the target matches the
  previous one, so switching between `build/` and `isofs/` chroots may run
  commands in the wrong tree.
- **[fixed]** (fragment builds them in; boots in QEMU) The initramfs `init` assumes `mdev` and busybox
  `switch_root`; the kernel config needs squashfs, overlayfs, isofs, udf, vfat,
  loop, devtmpfs built in or listed in `etc/x86_64/initfs/modules`.

### Side results from test builds
- Oct 2026: python3 **3.13.18 builds against OpenSSL 4.1.0** with the grimoire's
  `patches-3.13/0001-gh-146207-Add-support-for-OpenSSL-4.0.0.patch`; `_ssl`
  links `libssl.so.4`, and a verified HTTPS request works. (3.14.10 also
  builds against it.) To pick a python3 branch unattended, set
  `PYTHON3_BRANCH` in `build/etc/sorcery/local/depends/python3.p` before
  `cauldron chroot cast python3`; python3's triggers then recast
  python-dependent spells (setuptools, meson).
- rsync's DETAILS says `UPSTRAM_HASH` (typo for `UPSTREAM_HASH`).
- **sorcery bug (still on sorcery git master as of Oct 2026), for the sorcery
  maintainer:** `update_sorcery_scripts` in
  `var/lib/sorcery/modules/libsorcery` casts `basesystem` whenever that spell
  exists in the grimoire and isn't installed (a 2002-era block). Since
  `basesystem` and `smgl-base` conflict, `sorcery update` on a system using
  `smgl-base`/`smgl-system` (including tarballs cauldron builds) tries to
  dispel them and go back to `basesystem` — reported by a user on IRC. Fix
  options: skip the block when `smgl-base` is installed, or turn the
  `basesystem` spell into a deprecated placeholder (like `gnupg`).
  (`FORCE_BASESYSTEM_DEPENDS`, the other basesystem path, defaults to off.)
- wget vs OpenSSL 4: the wget spell picks its TLS library via `WGET_SSL`
  (gnutls / openssl / libressl). Unattended casts choose gnutls, so cauldron's
  wget is unaffected by OpenSSL 4; a user whose wget was built against openssl
  reported needing a patch after the OpenSSL 4 upgrade (wget2 avoided it).
- **Grimoire pattern to fix (python3, perl, likely others):**
  `optional_depends gdbm '' '' ...` — when the dependency is *off*, no
  `--without-...` flag is passed, so configure still finds the library in the
  build chroot and links it. sorcery then believes the spell doesn't need it
  (cauldron's `sys` check caught python3/perl dbm modules missing `libgdbm`;
  `gdbm` is now listed in `sys.runtime` as a workaround).
- Meta-spells (`smgl-base`, `smgl-system`, `smgl-mirrors`) set `ARCHIVE="off"`,
  so sorcery makes no cache for them; cauldron builds one from their install
  log (`cauldron_sorcerous_make_cache`).
- A cached spell built *without* an optional feature can be silently
  resurrected later even when a dependent asks for the feature (here: wget
  built `--without-ssl` before gnutls existed was resurrected when smgl-base
  requested "wget with SSL"). `cauldron_sys_check` now catches a wget without
  https.
- Reported but not investigated (outside the minimal tarball): mesa without
  llvm failing to build against current glibc headers; llvm spell default
  flags.

### Base tarball contents (decisions, Oct 2026)
- Principle: the base system must be able to rebuild itself (it's a source
  distro), so build-time tools needed by base spells stay in; size is kept
  down by options (presets), not by dropping those.
- `sys.runtime` = `smgl-base` + `smgl-system` + `bc` + `elfutils` (kernel
  builds) + `dhcpcd` (networking after first boot) + `man-db` + `gdbm` (see
  above), plus the init from `CAULDRON_SYS_INIT` (default `simpleinit-msb`:
  what the team expects and what sorcery's init-script prompts support;
  `systemd`/`openrc` variants are possible from the same caches but untested).
  `castfs`+`fuse` stay (staged installs). `git` goes on the ISO, not here.
- **Grimoire gap, for the team:** compared with `basesystem`, the
  `smgl-base` + `smgl-system` pair (2022) no longer pulls in `shadow` (login,
  passwd, useradd) or `lzip`; the hand-made tarballs also had `kbd` and
  `man-pages` installed separately. A system built from the two meta-spells
  alone can't be logged into. `sys.runtime` lists them explicitly for now;
  `smgl-system` should probably depend on `shadow` (and `kbd`).
- Presets in `etc/toolchain/sorcery/depends/`: `locale` (en_US + UTF-8 +
  C.UTF-8 instead of all locales, ~130 MB saved), `python3`
  (`--disable-test-modules`). Caveat: cauldron reuses existing caches, so
  after changing a preset, delete that spell's cache in
  `build/var/cache/sorcery` to force a rebuild.
- Stripping: sorcery already strips (`OPTIMIZATIONS` contains `strip`, i.e.
  `LDFLAGS -s`); gcc's own compilers (cc1, cc1plus, lto1) ignore it, which is
  most of gcc's ~290 MB — same in the hand-made tarballs.
- Later: `net-tools` is unmaintained (iproute2 is the modern tool and is
  already present via ifupdown); dropping it means changing `smgl-system` and
  `ifupdown`'s DEPENDS and `init.d`'s `hostname.sh` (uses net-tools'
  `hostname`). Saved spell options in the tarball are invisible to users
  until `cast -r` — consider listing them / an installer review step.
- Init on the ISO (stage 2): ship caches for several inits and let the
  installer choose; Rust is not needed for the kernel (keep `CONFIG_RUST`
  off), could be offered as an optional prebuilt cache.

### If a new baseroot tarball is ever made
The 2025-12 tarball works, but these differences from the current test
grimoire cost rebuild time and caused conflicts during `sys build`; a fresh
tarball should ideally:
- use `kmod` instead of `module-init-tools` (obsolete since 2011, still
  installed *and* sustained in the tarball; sorcery's default sustained list
  still names it — worth fixing in sorcery too)
- use `smgl-base` + `smgl-system` instead of the old `basesystem` meta-spell
- keep `gnupg-2.4` / `procps-ng` (the plain `gnupg` and `procps` spells are a
  deprecated placeholder and a 2009-era version respectively)
- drop the stale 3.4.51 kernel modules from `/lib/modules`
- optionally ship spell caches in `/var/cache/sorcery`, which would let
  cauldron skip compiling everything from scratch
- document how it was built (currently only the tarball maintainer knows)

### Already recorded by the previous maintainer
`cauldron/PROCESS` lists 2015-era spell failures (glibc kernel headers,
libmpc, util-linux, net-tools, pciutils, cryptsetup). Re-check against today's
test grimoire before carrying the `etc/toolchain/grimoire_hacks/` patches or
`depends` presets forward. `cauldron/TODO` has design TODOs (spell lists → config
arrays, tidy dir layout, operation tracking).

---

## 9. Suggested order of work

1. **toolchain** — local modern tarball as baseroot, `test` grimoire, x86_64.
   Fix the `run` dir, check sorcery/grimoire URLs, drop or refresh the grimoire
   hacks.
2. **Data files** — create `etc/x86_64/iso/` (runtime/install/sources/package
   lists derived from `etc/x86/*` + current spell names; `fstab`, `inittab`,
   `login.sh`, bootloader configs) and the `cauldron/data/cleaners/` lists.
3. **sys** — fix `cauldron_etc_configs` target types and `$state`; produce
   `system.tar.xz`; sanity-check it by chrooting into it.
4. **kernel + initramfs** — current LTS kernel, fresh x86_64 config
   (`defconfig` + the ISO needs above), current busybox config.
5. **bootloader/packaging** — `xorriso` hybrid image; isolinux (BIOS) +
   GRUB or systemd-boot EFI image (UEFI).
6. **enchant** — fix the enchanter paths/`$data`/host-path bugs; boot in QEMU
   (BIOS and OVMF) and walk through an install.

Keep this file updated as items in §8 get fixed (move them to a "Fixed" list
with the commit).

---

## 10. Conventions

**Upstream policy — read first.** GitHub is only a *mirror*; Source Mage's
source of truth is its own cgit. **Never open a pull request**, never push to
or target the upstream Source Mage GitHub repo, and never suggest doing so.
Work happens on branches in this fork only; working changes are carried
upstream manually by the maintainer via cgit, and reach GitHub from there.

- Bash, 2-space indent, 80 columns (see the `vim:` modelines).
- `function name() { ... }` with `local` vars; doc-comment blocks (`##`) above
  each function.
- Check errors with `liberror_check || return $?` / `|| return $ERR_X`; add new
  codes to `cauldron/lib/errorcodes`.
- Call external tools through `CAULDRON_CMD_*` arrays; add new ones to
  `config/commands.conf`.
- New tunables go in `config/*.conf` using `: "${VAR:=default}"`.
- Check syntax with `bash -n <file>`; `ward/ward-all` runs the old static checks.

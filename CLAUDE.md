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

**Later / nice to have:** ISOs for other arches (32-bit x86, ppc) via the
cross-compile path (`toolchain cross`, `cauldron_toolchain_build_cross`).
Most config and data is already per-arch (`config/arch/*.conf`,
`etc/<arch>/`). Note: `cauldron_toolchain_build_cross` relies on
`sorcery rebuild`, which the team reports doesn't always work.

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
- Point `CAULDRON_BASEROOT` at a **local** modern tarball (or an already
  unpacked directory) — the default `smgl-stable-0.61` URL is ancient. To
  re-run `toolchain` without re-unpacking, use
  `CAULDRON_BASEROOT=/tmp/cauldron/build` (a directory equal to
  `CAULDRON_BUILD` is used as-is).
- The defaults (`stable` grimoire, `http://` URLs, kernel 4.1.14) are still
  stale in `config/`. Until they're updated, put overrides in a small config
  file that sets them and then sources `local-exec/cauldron.conf`, and run
  `cauldron/bin/cauldron -f that.conf <command>` (with `CAULDRON_BASE` set to
  the repo). Example overrides:
  ```sh
  : "${CAULDRON_BASEROOT:=/root/smgl-test-0.63-20251212_1200-basesystem-x86_64.tar.xz}"
  : "${CAULDRON_SORCERY_BRANCH:=test}"
  CAULDRON_SORCERY_GRIMOIRES=( test )
  : "${CAULDRON_SORCERY_URL:=https://mirror.sobukus.de/files/sourcemage/sorcery/sorcery-test.tar.bz2}"
  : "${CAULDRON_SORCERY_GRIMOIRE_URL:=https://mirror.sobukus.de/files/sourcemage/codex}"
  : "${CAULDRON_KERNEL_VERS:=6.18.59}"
  : "${CAULDRON_KERNEL_URL:=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.59.tar.xz}"
  : "${CAULDRON_KERNEL_CONF:=/root/cauldron/cauldron/etc/x86_64/linux-4.1.14.config}"  # placeholder
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

### Status / fixed so far
- **`cauldron toolchain chroot` works** (Oct 2026) against the
  smgl-test-0.63-20251212 tarball + test grimoire + kernel 6.18.59 headers.
- Fixed on the working branch: `cauldron config` with several args; log
  truncation in `cauldron_chroot` (`&> /dev/stdout`); host arch detection
  (`host_arch.conf` yielded `i386`); `run` added to `CAULDRON_FHS_DIRS`;
  `$state` in `cauldron_sorcerous_spell_cache`; grimoire refresh path;
  obsolete 2015 glibc grimoire patch and dead glibc/squashfs-tools presets
  removed; `cauldron_etc_configs` now accepts `sys`/`iso`; `build_spells` no
  longer dispels spells the build chroot already had (it would have removed
  xz-utils, perl, kmod, ... from `build/`).

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
- **[suspected]** `cauldron_populate_sys` only unpacks caches into `sys/`; it
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
- **[confirmed]** `CAULDRON_DATA` = `cauldron/data/` doesn't exist, so the
  cleaner lists `cleaners/sys/*` and `cleaners/iso/*` used by `purify_sys` /
  `purify_iso` are missing (the glob stays literal, `sort` complains, and
  nothing is cleaned — silently "succeeds").
- **[confirmed]** `config/iso.conf` and `config/sys.conf` expect
  `etc/x86_64/iso/{iso.runtime,iso.install,iso.sources,iso.package}` and
  `etc/x86_64/sys/{sys.runtime,sys.install,sys.sources}`. Only
  `etc/x86_64/sys/` exists (`sys.install` and `sys.sources` are empty). There is
  **no `etc/x86_64/iso/` at all**; the only ISO lists are the older flat
  `etc/x86/iso.spells`, `iso.caches`, `iso.sources`.
- **[confirmed]** `libcauldron` also reads these non-existent files from
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
- **[confirmed]** `cauldron_add_enchanters` (`libcauldron:1007`) uses an
  undefined `$data` (lines 1018–1027) and copies from
  `$CAULDRON_ENCHANT_DIR/<enchanter>`, but enchanters live in
  `enchantment/enchanters/<enchanter>`.
- **[confirmed]** `cauldron_enchant` writes `welcome/editors` to
  `$ENCHANT_MODULES` on the **host**, not under the target
  (`libcauldron:1177,1181`), and line 1181 has a stray `\ ` after `column -t -s:`.

### Stale versions / URLs
- **[confirmed]** Defaults in `config/build.conf`: kernel 4.1.14 (configs for
  4.0.2/4.1.13/4.1.14 in `etc/x86_64/`), busybox 1.24.1, gcc 4.8.4, binutils
  2.25.1, make 4.1, perl 5.22.0, `CAULDRON_LIBC=musl` (SMGL uses glibc; only
  used by the unused from-scratch toolchain path), baseroot
  `smgl-stable-0.61-basesystem`.
- **[confirmed, override in use]** Grimoire/sorcery default to `stable`
  (`config/sorcery.conf`); goal is `test`.
- **[confirmed]** All download URLs are plain `http://` (sourcemage.org,
  kernel.org, busybox.net, gnu.org). Whether `download.sourcemage.org/sorcery/`,
  `codex.sourcemage.org/<grimoire>.tar.bz2` and `/image/official/` still serve
  these paths: they redirect to `mirror.sobukus.de` (see §7); the old
  `smgl-stable-0.61` baseroot is gone.
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
- **[confirmed]** Packaging is BIOS-only: `CAULDRON_CMD_MKISOFS`
  (`config/commands.conf:41`) uses isolinux El Torito flags;
  `CAULDRON_ISO_BOOTENV=efi` is half-implemented and the `grub` bootloader
  branch is empty. UEFI + USB needs `xorriso` with an EFI system partition image
  and a hybrid MBR/GPT.
- **[suspected]** `cauldron_chroot_init` only updates `CAULDRON_CHROOT` (the
  active chroot command) when it's the first chroot or the target matches the
  previous one, so switching between `build/` and `isofs/` chroots may run
  commands in the wrong tree.
- **[suspected]** The initramfs `init` assumes `mdev` and busybox
  `switch_root`; the kernel config needs squashfs, overlayfs, isofs, udf, vfat,
  loop, devtmpfs built in or listed in `etc/x86_64/initfs/modules`.

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

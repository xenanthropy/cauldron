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
- the maintainer wants this as its own planned project (Nov 2026), after the
  current ISO works end to end; they don't plan to use simpleinit-msb
  themselves. Note that the installer texts and base files assume
  simpleinit + init.d today (e.g. `/etc/sysconfig/bootmisc`, the `network`
  script running `ifup -a` from `/etc/network/interfaces`).
- providers in the test grimoire: `INIT` = simpleinit-msb, systemd, openrc
  (+ epoch, upstart); `INITSCRIPTS` = init.d, openrc. systemd works well;
  openrc is missing many service scripts (could be ported from Gentoo).

**Init system: decisions and draft plan (Nov 2026, maintainer + research;
nothing built yet).**
Decided: simpleinit-msb stays the default (the team expects it); the first
version adds systemd, openrc later (it needs service scripts, mostly the
*system* ones, ported from Gentoo; one SMGL developer does run it); the live
ISO itself stays on simpleinit; ISO size isn't a constraint; the maintainer
may update the systemd spell (they used it; it was last touched ~2023).

Findings that shape it:
- systemd 254.27 (spell) `CONFLICTS` eudev and elogind, `PROVIDES` INIT,
  DEVICE-MANAGER, LOGIN-DAEMON, SYSTEM-LOGGER; required DEPENDS include
  dbus, dracut, python3 + jinja2, gperf, libcap, util-linux (SULOGIN).
  `smgl-system` depends on INITSCRIPTS, so init.d stays installed under
  systemd (unused). openrc conflicts with init.d (it provides INITSCRIPTS).
- sorcery only installs SMGL init.d scripts (351 spells have `init.d/`);
  nothing installs systemd units or openrc scripts. Units come from the
  upstream build systems, which install them when they find systemd at
  build time; 76 spells have `optional_depends systemd` for that (units,
  sd_notify, logind). Caches built in a simpleinit build chroot therefore
  have no units: a system switched to systemd at install time would have
  systemd but its spells built as if it didn't exist.
- the systemd spell's FINAL runs `systemd-machine-id-setup`, so a systemd
  cache carries the build machine's /etc/machine-id (must be unique per
  machine; same class of problem as the SSH host keys): remove it from the
  sys tree/caches (systemd creates it at first boot when /etc/machine-id is
  empty or missing) and make `cauldron_iso_check` refuse one.
- the spell's SOURCE_URL is a systemd-stable GitHub archive; point releases
  moved into the main systemd repository (check the URL when bumping), and
  the agent sandbox can't fetch GitHub archives (needs an upload).

Options weighed:
1. one ISO, simpleinit system.tar.xz + systemd caches swapped in by the
   installer (`enchantment install init systemd`): offline and simple to
   use, but no units for the base system's spells (see above), and the
   swap has to fix up the logger, gettys, networking afterwards.
2. one ISO per init (recommended): cauldron already has
   `CAULDRON_SYS_INIT` (and picks the logger from it); build the systemd
   variant in its own `CAULDRON_TMP` (own build chroot, so systemd is
   present while every spell is cast and units get installed), giving
   `system.tar.xz` built for systemd and an ISO named for it. The
   installer then needs no swap step at all, and cauldron installs the
   init-specific texts (services, networking, logging, systemd-boot page)
   at `iso enchant` time from `CAULDRON_SYS_INIT`. Costs a second full
   build (hours) and the disk space of a second build tree (more than the
   agent sandbox has free; a build machine with ~40 GB is comfortable).
3. both tarballs on one ISO (~1 GB ISO), installer picks one: same build
   cost as 2, larger download for everyone.
4. network install of systemd from the installer: least work for
   cauldron, but needs network and compiles systemd and recasts on the
   user's machine during the install; little gain over casting it after
   first boot.

systemd version (from systemd 261.4's NEWS/README, Nov 2026): v255
removed support for an unmerged /usr (separate /bin and /usr/bin, /lib and
/usr/lib), which is SMGL's layout (system.tar.xz: 336 programs directly in
/bin + /sbin, 141 files in /lib). So 254.x is the last systemd for SMGL as
it is (likely why the spell stayed on the systemd-stable 254 branch;
254.27 updated ~spring 2026). Going newer needs a merged /usr: a team
decision (sorcery/spells install into /bin, /sbin, /lib directly). Later
releases also drop cgroup v1 (258), System V script support (260) and
need libxcrypt >= 4.4 (259). Kernel options systemd wants that the ISO
kernel lacks: USER_NS ("effectively required": PrivateUsers= in its own
units), BPF_SYSCALL + CGROUP_BPF (IPAddressAllow/Deny=), PSI (oomd),
CFS_BANDWIDTH (CPUQuota=), NET_SCH_FQ_CODEL, XFS/BTRFS POSIX_ACL; present:
DEVTMPFS, CGROUPS, AUTOFS, IPV6, FHANDLE, SECCOMP, ... Uploaded sources
(sandbox): systemd-stable-254.27.tar.gz, systemd-261.4.tar.gz.
Done (Nov 2026): those kernel options are in linux-iso.fragment for every
ISO (they only make features available; unprivileged BPF stays off,
BPF_UNPRIV_DEFAULT_OFF=y), config regenerated. User namespaces are on by
default (maintainer's decision, browsers' sandboxes need them); the shipped
/etc/sysctl.conf explains them and has `#user.max_user_namespaces = 0` to
switch them off on simpleinit systems; the edit-confs step mentions it.

Refinement (Nov 2026): how much actually differs. Of the ~104 spells in
system.tar.xz and the ISO's installable caches, the ones whose DEPENDS
mention systemd or a login daemon are only shadow (optional systemd),
procps-ng (optional elogind), and in the caches mdadm (suggest) and
nghttp2; plus eudev, which systemd replaces. gcc, glibc, binutils,
python3 etc. don't change. Some spells find systemd's pkg-config file
without declaring it and then install units (likely util-linux,
e2fsprogs, man-db, iputils, lvm; to be confirmed by building them with
systemd present and diffing their install logs). So a whole second build
isn't needed: "variant caches" in the same build chroot would do. Today
`CAULDRON_SYS_INIT` only adds the init spell to the sys spell list, picks
the logger (systemd: none) and suffixes the tarball's release name; it
changes nothing else, and setting it to systemd in the one build chroot
would leave systemd installed there (optional dependencies then default
to on for every later cast), hence the separate CAULDRON_TMP in option 2.
Maintainer's view: two ISOs per arch (four with 32-bit) is too much to
maintain; network + recompiling a few spells is acceptable for systemd
users (simpleinit stays the offline default).
5. variant caches, one ISO (recommended now): after the normal build, in
   the same build chroot: cast systemd (dispels eudev), recast the
   affected spells with their systemd options on, keep those caches and
   systemd's closure in a separate directory (same file names as the
   simpleinit caches, so not in /var/cache/sorcery), then put eudev and
   the simpleinit caches back. The ISO carries them under e.g.
   /var/cache/sorcery-systemd; `enchantment install init systemd` copies
   them into the target's cache directory and casts systemd + the
   affected spells: offline, no compiling, one ISO per arch.
6. the maintainer's network variant: ship systemd's caches (or not even
   those), and `enchantment install init systemd` recasts (`cast -c`)
   the affected spells with systemd on; simpler build side, needs network
   and a few minutes of compiling. Can be the first step towards 5 (same
   spell list, same installer command; 5 only adds prebuilt caches).

**systemd experiment (Nov 2026, build chroot, then undone).** systemd
254.27 builds in cauldron's build chroot (no linux-pam, no libseccomp:
logind sessions will need pam_systemd, so the real build turns pam on).
Order that worked: `cast flit-core` (jinja2 bug), dbus with
`dbus:systemd:off`, systemd with acl and docbook-xsl answered on (spell
bugs in the team report), then `cast -c` of the candidates with
`<spell>:systemd:on`. It dispels eudev; casts acl, attr, dbus, jinja2,
flit-core, libcap, docbook-dtd/-xsl, intltool, xml-parser-expat. Of 16
recompiled candidates, these differ (units / tmpfiles / libsystemd):
dbus, util-linux (fstrim, uuidd units; libsystemd), e2fsprogs (e2scrub
units), mdadm (8 units), xfsprogs (xfs_scrub units), cryptsetup-luks
(tmpfiles), shadow, procps-ng and lvm (libsystemd), openssh (its own
units; needed the daemon-reload fix). Unchanged: man-db, iputils,
nghttp2, kmod, dhcpcd, btrfs-progs. So the installer's recast list for
option 6 is: systemd (+ closure), dbus, util-linux, e2fsprogs, shadow,
procps-ng, lvm, openssh, plus mdadm/xfsprogs/cryptsetup-luks when
installed. The variant caches (21 files, 60 MB) were kept in the agent
sandbox only; the build chroot is back to its simpleinit state (same
spells, the original caches).

**systemd's options: proposed defaults (Nov 2026, draft for the
maintainer).** Since the systemd install goes over the network, size isn't
a constraint; pick what most systemd users expect, and cast the chosen
optional dependencies *before* systemd (with the answers preset) instead of
relying on sorcery to order them. From the experiment's build summary
(`meson` "Features"), what the spell's defaults gave and what to change:
- on, keep: kmod, acl (also needed for udev's `uaccess`, which gives the
  logged-in user access to GPU/audio/input devices), xz, zstd, libgcrypt,
  gnutls, openssl, elfutils (coredump backtraces), pcre2 (`journalctl -g`),
  man pages (libxslt + docbook-xsl); CONFIGURE's binfmt, hostnamed,
  timedated, localed.
- turn on: **linux-pam** (pam_systemd registers logins with logind: no
  logind session, no XDG_RUNTIME_DIR, no `uaccess`, no user manager
  without it), **libseccomp** (units' SystemCallFilter= is ignored
  without it; small, no dependencies), libidn2 instead of the deprecated
  libidn, lz4 (small; reads journals compressed with it), and
  **systemd-boot** (needs `bootloader=true` + pyelftools; see the team
  report: the spell's gnu-efi switch doesn't do it).
- on (maintainer, Nov 2026): policykit (unprivileged reboot/poweroff,
  hostnamectl etc. from a user session; most desktops want it). What
  polkit 128 really needs, from its meson files: glib2 >= 2.44, expat,
  duktape, perl (undeclared; in the base system), gettext (msgfmt for the
  action files), libsystemd for `session_tracking=logind`, linux-pam for
  `authfw=pam`; dbus only at run time (`dependency('dbus-1', required:
  false)`, used for install paths). Not needed: python3, dbus-glib (see the
  team report). Cast it *after* systemd (it needs libsystemd).
- ask (default off): libcryptsetup for crypttab/cryptenroll (the spell's
  `optional_depends cryptsetup` names the wrong spell, see the team
  report).
- off: audit, selinux, qrencode, microhttpd (journal-remote), p11-kit,
  libfido2, xkbcommon, dracut (until the initramfs project), lxml.
  Hard-coded off in BUILD: homed, userdb, sysusers, firstboot.
PAM is the part with knock-on work: shadow (`login`, `su`, `passwd`),
openssh and sudo must be recast `--with-pam`, openssh also needs `UsePAM
yes` in sshd_config, and the PAM stack has to call pam_systemd. The pam.d
files spells ship are standalone pam_unix lines without pam_systemd
(sorcery's `install_pam_confs` installs a spell's `pam.d/` files only when
missing), and shadow's and openssh's `passwd` lines say `md5`, so password
changes through PAM would store MD5-crypt hashes. Plan: the installer
writes a small PAM set first (a `system-auth` modelled on systemd's
`usr/share/factory/etc/pam.d/system-auth`: pam_unix with yescrypt/sha512,
`-session optional pam_systemd.so`; `login`, `su`, `sshd`, `sudo`,
`passwd`, `other` including it), then casts. Cast order for `install init
systemd`: libseccomp, linux-pam (logind off), acl, pyelftools, libidn2, lz4,
dbus (systemd off) -> systemd -> dbus, util-linux, e2fsprogs, procps-ng,
lvm, shadow, openssh, sudo (with systemd/pam on) -> linux-pam again
(logind on), plus mdadm/xfsprogs/cryptsetup-luks when installed.
Loops, and sorcery's tool for them: `runtime_depends` (libdepends) puts the
dependency in the same cast queue without making the spell wait for it
(no build-order edge; `suggest_depends` are handled the same way). systemd
254 doesn't build against libdbus (meson: `dbus` option "libdbus support
(for tests only)"; it has its own sd-bus); it needs the dbus daemon only at
run time. So systemd's `depends dbus` should be `runtime_depends dbus`:
then dbus is no longer forced before systemd, and its own `optional_depends
systemd` orders it after systemd, which ends the dbus loop (to verify in a
cast). Likewise systemd's `optional_depends policykit` only installs
polkit rules (polkit is looked up with `required: false`, for a version
check), while policykit needs libsystemd: building systemd with
`polkit=true` and casting policykit afterwards avoids that loop. linux-pam
<-> systemd is a real build-time loop in both directions (pam_systemd links
libpam; linux-pam's logind option links libsystemd); linux-pam's logind
support is minor, so leave `linux-pam:systemd:off` (or recast it once
afterwards). What it does (linux-pam 1.7.3 source, `USE_LOGIND`): three
modules ask logind instead of utmp: pam_issue's `\U` (number of logged-in
users in /etc/issue), pam_limits' `maxlogins`/`maxsyslogins` counting, and
pam_timestamp's login-time check. Nothing else; worth it only for someone
using those. SUB_DEPENDS can't help: it asks for a dependency built with
given options, which still has to exist before the spell. Also wanted
with PAM: `PAM_CHKPWD_SUID=y` (linux-pam's question), so screen lockers
running as the user can check passwords via unix_chkpwd. To verify
in the next build: logins get a logind session (`loginctl`), `systemctl
--user` works, `bootctl install` works.

Steps for option 2: (a) bump the systemd spell to the latest release and
build it once in a scratch chroot; (b) a systemd `base_etc`/config
variant (no inittab/sysconfig init bits; getty@tty1..6 enabled; network:
dhcpcd.service or systemd-networkd; journald instead of metalog; an empty
machine-id); (c) `sys` with `CAULDRON_SYS_INIT=systemd` in a separate
`CAULDRON_TMP`, check for units of the base spells; (d) `iso` for it with
init-specific installer texts; (e) QEMU install + boot test, as for the
simpleinit ISO. Open: name scheme of the two ISOs; whether the team wants
to publish the systemd one at all at first.

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
- **Optional initramfs (planned, maintainer's wish, Nov 2026):** SMGL
  traditionally boots without one, and that stays the default; the installer
  should offer one as a choice and explain it: needed for root on
  LUKS/LVM/mdadm, a root filesystem driver built as a module (e.g. a
  distribution-style kernel config like Void's), `root=UUID=`, early
  microcode; not needed when the root filesystem's driver is built in. With
  one, GRUB changes: `grub-mkconfig` picks up `/boot/initramfs-<ver>.img`
  (or `initrd.img-<ver>`) by itself and `root=UUID=` works, so
  `GRUB_DISABLE_LINUX_UUID` can go back to false. Generators in the test
  grimoire: dracut 112 (dracut-ng), mkinitcpio 41.1, and SMGL's own
  `linux-initramfs` scripts used by the `linux` spell. Plan: an installer
  step between kernel and boot-loader (guide text + caches for the chosen
  generator), tested in QEMU with root on ext4 and on LUKS.
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
  - grub2's SMGL splash (`smgl-splash.png`, 640x480, 4 KB, installed to
    /boot/grub) never shows (noticed on the hardware, Nov 2026), for two
    reasons: `grub-default` sets `GRUB_BACKGROUND="smgl-splash.png"`, and
    grub-mkconfig tests that path relative to its working directory
    (cauldron's hack now uses `/boot/grub/smgl-splash.png`); and the
    background needs the graphical terminal, which needs a font
    (unicode.pf2), which grub2 only makes with the optional `unifont` +
    `freetype2` dependencies (off in an unattended cast); and even with
    unifont on, GRUB's configure only looks for unifont.{pcf,bdf,ttf}
    while the unifont spell installs unifont.otf, so no font is made.
    Without a font, grub-mkconfig quietly falls back to the text menu.
    Cauldron now turns both on (`default_depends`) and its grub2 hack
    passes `--with-unifont=/usr/share/fonts/unifont/unifont.otf`. Built
    (Nov 2026): "With unifont from .../unifont.otf", the grub2 cache has
    usr/share/grub/unicode.pf2 (2.4 MB) and grub-mkfont. Cost on the ISO:
    ~10 MB of caches (grub2 +1.1, freetype2 3.1, brotli 2.2, unifont 2.4,
    smgl-foma 1.3). The splash itself is still to be seen at the next ISO
    test (QEMU screenshot of the installed system's GRUB menu).
  - wpa_supplicant 2.11 doesn't build against OpenSSL 4 (`ASN1_STRING` is
    opaque now; `tls_openssl.c` uses `->data`/`->length`). Cauldron patches
    it (`grimoire_hacks/wpa_supplicant`); other distributions carry the same
    accessor fix.
  - sudo 1.9.17p2 doesn't build against OpenSSL 4 either
    (`lib/iolog/hostcheck.c` reads `iPAddress->length`; two lines). So a
    plain `cast sudo` fails on any up-to-date system. Cauldron patches it
    (`grimoire_hacks/sudo`); newer sudo releases may already have the fix.
  - dosfstools 4.2 is built without `--enable-compat-symlinks`, so there is
    no `mkfs.vfat` or `fsck.vfat`: the usual documentation fails, and the
    boot-time fsck of a vfat fstab entry (the EFI system partition) can't
    find its checker. Cauldron adds the flag (`grimoire_hacks/dosfstools`).
  - wireless-regdb only installs the CRDA file (`/usr/lib/crda/
    regulatory.bin`); kernels since 4.15 load `/lib/firmware/regulatory.db`
    (+ `.p7s`), so without it wifi stays in the restrictive world regulatory
    domain ("failed to load regulatory.db" at boot). Cauldron patches the
    INSTALL (`grimoire_hacks/wireless-regdb`).
  - nscd (glibc, started at boot) watches `/etc/netgroup`, which nothing
    installs, so it prints "stat failed for file `/etc/netgroup'" on the
    console at every boot, in the middle of the login prompt (found on the
    hardware). The default `nsswitch.conf` still names NIS/NIS+ for every
    database, although glibc no longer ships those modules. Cauldron ships
    an empty `netgroup` and a files/dns `nsswitch.conf` (`base_etc`).
    Related: boot scripts still run while the gettys already show the
    login prompt, so any late boot message lands in it.
  - eudev's rules use the groups `render` and `sgx`, which SMGL's
    `/etc/group` (smgl-base / init.d) doesn't have ("specified group
    'render' unknown" at boot): the nodes get group root (render nodes are
    0666 anyway; /dev/sgx_* are 0660, so root-only). Cauldron's shipped
    `group` adds sgx (27) and render (28).
  - grub2 builds one platform per cast (`i386-pc` *or* `x86_64-efi`); a
    cache for a hybrid ISO / installer has to be assembled from two casts
    (cauldron does this in `cauldron_iso_grub_cache`). A spell option to
    build several platforms would be simpler.
  - zile 2.6.4 (rewritten in Vala) needs glib2, libgee and vala, but its
    DEPENDS only lists help2man, ncurses and libgc, so it fails in
    configure. (The ISO ships jed instead.)
  - vim's stable branch is 9.0.1637 (June 2023); vim has had many
    security fixes since. jed's SOURCE_URL is ftp://space.mit.edu; the
    releases are on https://www.jedsoft.org/releases/jed/ (signatures as
    `.asc`).
  - iputils (ping) is 20221126; upstream is at 2025 releases. Nothing in
    `smgl-base`/`smgl-system` provides ping at all (found on the hardware:
    the installed system had none); cauldron adds iputils to `sys.runtime`.
  - sorcery records build-only dependencies as ordinary dependencies (e.g.
    libssh `depends cmake`, its build system), so the ISO's installable
    caches carry cmake and its dependencies (curl, jsoncpp, libarchive,
    rhash, libuv: ~35 MiB) that nothing needs at run time. Leaving them out
    would make sorcery try to build cmake offline when libssh is installed;
    a build/run distinction in DEPENDS would solve it.
  - jinja2 3.1.6 builds with the flit_core backend (pip: "BackendUnavailable:
    Cannot import 'flit_core.buildapi'"), but its DEPENDS lists only
    python3, pip, markupsafe (+ suggest babel): add `depends flit-core`
    (the spell exists, python-pypi/flit-core). Any system without
    flit-core installed fails to cast jinja2, so systemd too (found
    building systemd, Nov 2026).
  - dbus and systemd depend on each other: systemd `depends dbus`, and
    dbus `optional_depends systemd`, which defaults to on while systemd
    is being cast, so dbus fails with "Dependency libsystemd not found".
    Order needed: dbus without systemd, then systemd, then dbus again
    with systemd (cast -r dbus). Sorcery can't resolve the loop by itself.
  - systemd 254.27's spell sets ACL support twice: `optional_depends acl`
    passes acl=true/false, and CONFIGURE's `config_query_option
    SYSTEMD_ACL "Enable ACL support?" y` adds acl=true afterwards, so with
    the acl dependency off meson still requires libacl and fails
    ("Dependency libacl not found"). Drop one of the two (the
    optional_depends is the one that also installs acl). Likely the same
    pattern for EFI (gnu-efi passes efi=..., SYSTEMD_EFI too).
  - systemd 254.27 builds with `man=auto`: with libxslt installed it builds
    the man pages, which need the DocBook stylesheets, but docbook-xsl is
    only a `suggest_depends` (off by default), so the build fails at
    "compilation error: file ../man/custom-man.xsl line 12 element
    import". Either `depends docbook-xsl` when libxslt is there, or pass
    man=true/false from that suggest's answer. (Also: with the suggest
    answered "on", sorcery cast docbook-xsl *after* systemd, so the first
    build still failed; suggest_depends aren't ordered before the spell.)
  - openssh's INSTALL runs `systemctl daemon-reload` whenever systemd is
    installed, which fails without a running systemd (a chroot, a build
    machine, the installer), so `cast openssh` fails there after systemd
    is cast. Run it only if `/run/systemd/system` exists (cauldron's
    openssh hack does). Other spells' INSTALLs may do the same.
  - systemd 254.27's `optional_depends gnu-efi "efi=true" "efi=false"`
    no longer builds systemd-boot: since v253 sd-boot is built by meson's
    `bootloader` option and needs pyelftools (python-pypi/pyelftools), not
    gnu-efi. With `bootloader=auto` and no pyelftools there is no
    systemd-boot, no bootctl, no systemd-stub. Fix: `optional_depends
    pyelftools "bootloader=true" "bootloader=false"`, and drop gnu-efi.
    (`efi` still exists in 254: general EFI support, e.g. `systemctl
    reboot --firmware-setup`, the boot loader interface, gpt-auto's ESP
    mount. systemd-boot, systemd-stub and bootctl are built only when
    `efi` is true *and* `bootloader` is auto/true *and* pyelftools is
    found. The gnu-efi answer passes efi=false, then CONFIGURE's
    SYSTEMD_EFI adds efi=true, and meson keeps the last one, as with acl.)
  - systemd's `optional_depends cryptsetup ... libcryptsetup=true` names
    `crypto/cryptsetup`, version 0.1 from 2004 (saout.de), instead of
    `cryptsetup-luks` (2.8.1, which provides libcryptsetup).
  - systemd and linux-pam depend on each other optionally (pam=true;
    linux-pam's `logind=enabled`), the same kind of loop as dbus: linux-pam
    first without systemd, then systemd, then linux-pam again.
  - The pam.d files of shadow (`login`, `passwd`) and openssh (`sshd`) use
    `pam_unix.so ... md5`, so with linux-pam on, `passwd` stores MD5-crypt
    hashes (login.defs' ENCRYPT_METHOD is bypassed). Use yescrypt or
    sha512, ideally through a shared `system-auth` that the others include.
    Also openssh `--with-pam` keeps sshd_config's default `UsePAM no`.
  - policykit (128, gnome2-libs; much of the spell dates from polkit
    0.9x, 2008-2009): `depends dbus-glib` and `depends python3` are not
    used by polkit 128's build (glib's GDBus replaced dbus-glib in 0.104,
    2012); dbus is only a run-time need (runtime_depends); perl is used
    (src/polkitbackend/toarray.pl) but not declared; BUILD still creates the
    0.9x `polkituser` account; PRE_BUILD applies a `patches` directory the
    spell doesn't have. More important: polkit's PAM file
    (`/usr/lib/pam.d/polkit-1`; linux-pam reads /usr/lib/pam.d after
    /etc/pam.d) is four `include system-auth` lines, and SMGL has no
    `system-auth`. linux-pam turns a failed include into a must-fail entry
    (`PAM_HT_MUST_FAIL` in libpam/pam_handlers.c), so every polkit password
    prompt fails at once, as if the password were wrong (seen by the
    maintainer on their own systemd install). Fix: ship a `system-auth`
    (linux-pam, or the PAM set planned in section 1). Also, CONFIGURE's
    session tracker list starts with elogind, so an unattended cast picks
    elogind, which conflicts with systemd: put systemd first when systemd
    is installed (cauldron presets `POLKIT_SES=systemd`).
  - systemd's `depends dbus` is only a run-time need (see the loops note
    in section 1): `runtime_depends dbus` would end the dbus <-> systemd
    loop. Its `optional_depends policykit` doesn't need polkit at build
    time either.
  - `cryptsetup` (0.1, 2004) is superseded by `cryptsetup-luks`, which
    CONFLICTS with it, but it was never turned into a deprecated
    placeholder (an empty spell that depends on cryptsetup-luks); it still
    points at saout.de. Deprecating it needs the team's approval.
  - sorcery's default sustained list has acl and attr, so `dispel acl`
    does nothing without `--nosustain` (noticed undoing the systemd
    experiment, which had cast them).
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
- **Installer text**: the welcome screen now points to
  `#sourcemage-cauldron` on irc.libera.chat (was freenode; the maintainer
  would rather funnel everything into `#sourcemage`). Open question for the
  team: who receives `iso@sourcemage.org`, also named there?
- **sorcery**
  - `update_sorcery_scripts` casts `basesystem`, which conflicts with
    `smgl-base` (`sorcery update` tries to replace smgl-base/smgl-system).
  - The default sustained list still names `module-init-tools`.
  - `DEF_INSTALL_INIT`/`DEF_ENABLE_INIT` default to off, so an unattended
    cast (cauldron's builds, scripted installs) never installs a spell's init
    script: metalog's caches had no `smgl-metalog`, openssh's no `sshd`.
    Cauldron's presets answer it per spell (`depends/metalog`: installed and
    enabled; `depends/openssh`: installed, disabled).
  - `MAKE_NJOBS` defaults to 1 (`/etc/sorcery/compile_config`), and without
    distcc that is the whole `make -j`: a fresh install compiles on one
    core until the user finds the setting. A default of `$(nproc)` would
    suit a source distribution better; the installer's edit-confs step
    tells the user for now.
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
      - installed system (20261102, Nov 2026): text scrolling on the
        console tears. i915 is fine (DMC/GuC/HuC loaded, GuC submission
        on); it is fbcon redrawing the whole screen in software on every
        scroll (no acceleration since 5.11, no vsync), slowest with
        rotation and the 16x32 font. A GPU-drawn console (kmscon) or a
        graphical session avoids it. Found alongside: the ISO kernel had
        no CONFIG_FB_DEVICE (no /dev/fb0, /proc/fb; fbterm and friends
        can't run) and no CONFIG_TRANSPARENT_HUGEPAGE (i915: "Transparent
        Hugepage support is recommended"); both on in the fragment now
        (THP madvise), config regenerated; not yet in a built kernel.
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
  - Also from the hardware test: eight steps' instructions tell the user to
    type `$ENCHANT_TARGET`/`$ENCHANT_TMP`, which login shells didn't have
    (now exported by `/etc/profile.d/enchantment.sh`; workaround on older
    ISOs: `export ENCHANT_TARGET=/mnt/smgl ENCHANT_TMP=/tmp/enchantment`);
    and the disk partition/format/mount texts were from ~2010 (hd* names,
    reiserfs, no UEFI/GPT): rewritten. The other steps' texts deserve the
    same review. (Note: cauldron's `@VAR@` substitution in instructions uses
    `sed s/../../`, so values containing `/` would break it.)
  - Found on the hardware with the 20261030b ISO: `/mnt/smgl`
    (`$ENCHANT_TARGET`) didn't exist on the live system, so the mount step's
    `mount ... $ENCHANT_TARGET` failed; `cauldron_enchant_init` creates it
    now (workaround: `mkdir -p $ENCHANT_TARGET`).
  - Also from that install: the spell-caches/spell-sources steps promised
    "a text menu for toggling" that never existed (`select caches` only
    printed the list) and named the wrong files (`spell_caches`). `select
    caches|sources` without an action now opens a `dialog` checklist
    (`enchant_shell_select_menu`, `ENCHANT_CMD_DIALOG`); texts rewritten. The
    edit-confs step pointed at `/mnt/root/...` and a non-existent
    `list-editors`; `todo` (re-print the current step) is now mentioned on the
    welcome screen, and `steps` is an alias of `list`.
  - Editors (from the same install): `help editors` was a static 2010 list
    (nano, elvis, jed) while the ISO had nano, busybox vi and ed. cauldron
    now writes `help/editors` from `CAULDRON_ISO_EDITORS`, listing only the
    editors present in `isofs/`. Added to the live system: vim (console
    only; preset `depends/vim` + `default_depends` keep perl/python/... out;
    vi links to it) and jed (Emacs key bindings, ~4 MB with slang). Real
    emacs pulls in X/GTK (>100 MB) and helix needs rust, so neither is on
    the ISO. Sandbox note: vim's source (a GitHub archive) can't be fetched
    from the agent sandbox and wasn't found on any mirror; jed's was
    pre-fetched from jedsoft.org.
  - fstab (from the same install): the shipped `base_etc/fstab` now has
    commented examples for ext4/XFS/btrfs subvolumes/ESP/swap/tmpfs and
    `devpts` with `gid=5,mode=620` (SMGL's `mountall.sh` mounts proc, sys
    and devpts from fstab, so those lines must stay). `guide disks` gained
    zram (kernel `CONFIG_ZRAM=m` with zstd/lz4 backends; set up via the
    executable `/etc/sysconfig/bootmisc`, SMGL's rc.local) and sorcery's
    `TMPFS` option (compiling in RAM; tmpfs defaults to half of RAM, big
    spells set `TMPFS=off` themselves).
  - Step texts longer than the screen (compile-kernel, edit-confs, grub,
    welcome on an 80x25 console) scrolled out of sight on a console without
    scrollback; `todo`/`next`/`prev` now print through `less -XFR`, which only
    pages when the text doesn't fit (with a prompt naming the keys). Its
    prompt says `MORE BELOW` until the end, then `(END)`: with -X the
    screen keeps what was shown after quitting, which looked like the whole
    text (on the hardware, the grub page's last steps went unseen).
  - `enchantment chroot` (found on the hardware, Nov 2026): leaving the
    interactive chroot reported "could not execute chroot command" whenever
    the last command typed in it had failed, and then skipped the cleanup,
    so the next chroot stacked proc/sys/... again ("umount ... efivars: not
    mounted"). Worse, the cleanup unmounted *every* mount below the target,
    including the user's EFI system partition on `boot/efi` (also after the
    chroots `install caches` runs). `enchant_chroot_close` now unmounts only
    run/sys/proc/dev (recursively, looping over stacked mounts), and the
    exit status of an interactive chroot shell is ignored. Tested with a
    stand-in ESP: it stays mounted in all cases.
  - efivarfs (same install): the live system never mounted it, so
    `efibootmgr` said "EFI variables are not supported" until the user
    mounted it by hand. The live login profile now mounts it on UEFI
    machines, and `enchant_chroot_init` mounts it inside the target's /sys
    (the grub step no longer asks for it). Still to verify under OVMF at
    the next ISO test (the agent sandbox has no UEFI).
  - user-setup/reboot (same install): `smgl-setup` (the post-install man
    page the reboot step points to) wasn't in the system tarball although
    the text said "installed by default"; it is in `sys.runtime` now. The
    user-setup step adds the user to `wheel` and explains sudo (`visudo`,
    `%wheel ALL=(ALL:ALL) ALL`) and doas; `sudo` is offered as a cache
    (`iso.install`, optional deps off in `default_depends`); opendoas
    hard-depends on SYSTEM-LOGGER, so it is left to `cast opendoas`. For
    the team: smgl-setup's man page dates from 2008 (stable grimoire, a
    separate g++ spell) and could use a refresh.
  - ISO size (20261030b, 637 MiB; answered for the team, Nov 2026):
    isofs.img 578 MiB = system.tar.xz 315 (already xz) + live runtime
    ~125 compressed (583 MiB raw) + installable caches 93 (24 tarballs,
    .tar.bz2; cmake 26 and grub2 19 the largest) + firmware ~19 (80 raw,
    250 files picked by `cauldron_iso_firmware`) + kernel modules ~6;
    plus kernel 15, initramfs 7, GRUB/EFI image. linux-firmware isn't
    shipped whole (that would be ~1 GB); the installed system gets the same
    selection via `install iso-kernel`.
  - ping (first boot of the installed system): none existed (the live ISO's
    is busybox's). iputils is in `sys.runtime` now (libcap/libidn2/libxslt
    off) and the shipped `/etc/sysctl.conf` sets
    `net.ipv4.ping_group_range = 0 2147483647` so users can ping without a
    setuid binary.
  - Hostname: `enchantment hostname NAME` writes `/etc/hostname` and the
    `127.0.1.1` line of `/etc/hosts` (cauldron now ships `hosts` with
    `127.0.1.1 sourcemage`, matching the default hostname), so the name
    always resolves (sudo warns otherwise).
  - Boot scan left the machine's own EFI partition mounted (found on the
    hardware, Nov 2026: parted "unable to inform the kernel of the change",
    cfdisk "device is in use"). When the boot medium isn't found among the
    removable devices (a USB stick that shows up late), `scan_cdrom` tries
    every partition in /proc/partitions as iso9660/udf/vfat; a vfat ESP
    mounted fine, wasn't the ISO, and stayed mounted, read-write, on the
    initramfs' `/mnt`, out of sight after switch_root (again at every
    rescan). Besides blocking repartitioning, a later mount of a freshly
    formatted ESP would reuse that stale superblock. `test_mount` now
    mounts read-only and unmounts every miss (`release_mount`); it also
    reported the wrong device ("found: /dev/vda1"). Verified in QEMU (FAT
    disk scanned before the ISO): `blockdev --rereadpt` fails before,
    works after. Workaround on older ISOs: zero the ESP's first MiB
    (`dd if=/dev/zero of=/dev/nvme0n1p1 bs=1M count=1`; verified on the
    hardware), reboot the ISO,
    then format it. `wipefs -a` is not enough (tried on the hardware): it
    only erases the "FAT32" string blkid looks for, and the kernel's vfat
    driver doesn't check that string, so the scan still mounted it.
  - Fresh local install on the hardware with smgl-devel-20261102 (Nov
    2026, in progress): efibootmgr works on the live system with nothing
    mounted by hand (efivarfs fix confirmed). The welcome screen opens in
    less on the rotated 16x32 console (it is ~1 line too long for that
    screen): to do, shorten it (e.g. move network/SSH into a `guide
    network` page) so no one lands in a pager first thing. `select caches`
    menus now use sorcery's dialog colours (cauldron copies the build's
    `/etc/sorcery/dialogrc` to `/etc/enchantment/dialogrc`,
    `ENCHANT_DIALOGRC`); not yet in a built ISO.
  - Installable caches vs grimoire (found on the hardware, Nov 2026):
    `install caches` with libssh ticked (the maintainer's pick; libssh
    needs cmake, which needs libarchive and libuv) dropped libssh, cmake,
    libarchive and libuv (with cryptsetup-luks, which needs libssh, also
    that). `sys purify` downloaded the newest grimoire
    (Nov 2) into system.tar.xz, while the caches were built on Oct 28 from
    the build chroot's older one; libarchive (3.8.10 -> 3.8.11) and libuv
    (1.52.1 -> 1.53.0) had changed, sorcery only resurrects a cache whose
    version matches its grimoire, so it tried to compile them, the
    downloads failed offline, and their dependents were dropped. Yet
    `install caches` reported success (cast returns 0). Fixed:
    `cauldron_sorcerous_update_grimoires` gives sys/iso a copy of the build
    chroot's grimoire; `cauldron_iso_check` fails when system.tar.xz's
    grimoire VERSION differs from the build chroot's; `install caches`
    checks sorcery's records afterwards and names what wasn't installed.
    Reproduced in a chroot with the 20261102 tarball and caches (same five
    dropped); with the build grimoire all five resurrect. Workaround on
    that ISO: skip libssh/cryptsetup-luks (openssh doesn't use libssh; root
    on LUKS needs an initramfs anyway) and `cast` them after first boot, or
    get online first so sorcery can compile libuv/libarchive. Also: the
    `select caches` menu listed every cache on the ISO, including ones that
    are only there as dependencies (libssh, cmake, curl, ...), which
    invited ticking them. Now cauldron writes the caches of the spells
    named in `iso.install` to `/etc/enchantment/caches.main`
    (`cauldron_iso_install_caches`), and the menu, `show` and `all` offer
    only those (`ENCHANT_CACHES_MAIN`); `add` still takes any cache by
    name, and the menu keeps selected entries it doesn't show. Tested in
    the live tree (show/add/all, and the dialog driven over a pty).
  - Kernel steps (maintainer's review, Nov 2026): `iso-kernel` and
    `compile-kernel` were steps of their own after `kernel`, so `next`
    from the kernel overview led into iso-kernel even after compiling.
    They are now only `todo` pages (`enchanters/shell/modules`: kernel ->
    boot-loader); the kernel step says which kernels sorcery tracks (only
    the linux spell's), and compile-kernel's manual part says what that
    means (no updates, no dispel, don't hand-build the spell's version).
    The same for the boot loader: `grub` is a page of the `boot-loader`
    step (boot-loader -> user-setup), which also names the grimoire's
    other boot loaders, each with its own page (`todo limine|refind|
    syslinux|lilo`; their spells aren't on the ISO: cast with network from
    `enchantment chroot`). Written from the spells and upstream docs, not
    yet tested: limine 12.9.4 depends on llvm/clang and only reads FAT
    (kernel on the ESP, simplest with the ESP at /boot; so the
    disk-partition step suggests 1 GiB for an ESP holding kernels, and the
    disk-mount step has a note on mounting it at /boot for Limine); rEFInd 0.14.2 is
    UEFI only (`refind-install`; `/boot/refind_linux.conf` by hand, since
    `mkrlconf` would copy the ISO's cmdline); syslinux 6.03's extlinux
    can't use ext4 with the 64bit feature (mkfs.ext4's default); lilo
    24.2 is BIOS/MBR only. To test them in QEMU at a later ISO round.
    The grub page (46 lines) had grub-mkconfig at line 39: on the
    maintainer's rotated console `less` showed the first screen only, so
    the menu step went unseen. It now starts with the three steps
    (grub-install, check /etc/default/grub, grub-mkconfig) and numbers
    them below.
    systemd-boot gets a page with the init-system project (it comes with
    systemd); gummiboot (its 2015 predecessor) is left out.
    Checked: nothing in smgl-base/smgl-system depends on the linux spell
    and system.tar.xz doesn't have it; in the test grimoire only
    wireguard-modules hard-depends on it.
  - Idea (maintainer, Nov 2026; not started): build the ISO kernel with the
    linux spell instead of cauldron's own `make` (`cauldron_iso_kernel`),
    so `install iso-kernel` can resurrect a linux cache and sorcery tracks
    the installed kernel (updates via `sorcery queue`). Findings: the test
    grimoire's linux spell only offers its current line (`info/kernels`:
    7.3, not the 6.18 LTS the ISO uses); it can run unattended with preset
    answers (`MAKEMODE=oldconfig`, `CONFIG_RESTORE=<our .config>`,
    `UPDATE_BL=n`); it installs /boot/vmlinuz-VERSION (+ System.map,
    config) and /lib/modules; its build dependencies (bc, perl, bison, flex,
    elfutils, xz) are all in system.tar.xz already, so resurrecting needs
    nothing new. To check: cache size (does /usr/src/linux-VERSION end up
    in it?) and whether the ISO's firmware selection should become
    linux-firmware. Fits with the generic-kernel project.
  - To do before a public test ISO (maintainer, Nov 2026): decide how much
    the installer configures before first boot; refresh smgl-setup's man
    page (2008: calls Debian's `interfaces` a recent switch, assumes the
    stable grimoire; the networking part ties in with the init-system
    project).
  - Directory modes (found on the hardware, Nov 2026: `gaze` as a user:
    "mkdir: cannot create directory '/tmp/liblock-1000': Permission
    denied"): system.tar.xz had /tmp and /var/tmp as 0755 (only root could
    write: breaks nearly everything a user runs), /root 0755 instead of
    0750, and no /var/spool/mail. smgl-fhs makes them with those modes in
    its INSTALL, but caches don't record directory modes, and cauldron made
    the directories with a plain mkdir. Now `CAULDRON_FHS_MODES`
    (config/build.conf: tmp 1777, var/tmp 1777, root 0750, var/spool/mail
    3775 group mail) applied by `cauldron_fhs_modes` at the end of sys
    populate and iso populate, and `cauldron_sys_check` fails on a wrong
    mode. Tested on a scratch tree. Fix on installed systems:
    `chmod 1777 /tmp /var/tmp; chmod 0750 /root`.
  - Battery (found on the hardware, Nov 2026: the laptop ran flat
    mid-install, as a console shows no charge): `acpi` (acpiclient, no
    dependencies) is in the live system and offered as a cache; the welcome
    screen mentions `acpi -b`. Without it:
    `cat /sys/class/power_supply/BAT*/capacity`. Not yet in a built ISO.
  - Code scan (Nov 2026): `ERR_MODULE_FILE` was used but never defined (a
    missing module list returned success); `enchantment install headers`
    called `enchant_install_kernel_headers_${!ktype}` (indirect expansion,
    so an empty name); the iso-kernel step's manual commands copied a
    non-existent modprobe blacklist and left out the firmware and depmod;
    the boot-loader step named removed steps (select-spells, install) and
    lilo, which isn't on the ISO (also dropped from the step order). The
    old `ward` checks still flag the dead toolchain build/cross calls; its
    error-code check reads the wrong file for enchantment (false alarms).
  - Grimoire metadata (found on the installed system): `scribe update` asked
    "Repair Grimoire:/var/lib/sorcery/codex/test's Metadata?" because cauldron
    unpacks grimoire tarballs itself and never wrote the `GRIMOIRE` file
    (`FROM_URL=...`) that `scribe add` creates. `cauldron_sorcerous_install_
    grimoires` writes it now (the mirror URL it downloaded from).
  - System logger (found on the installed system: nscd's 22 start-up lines
    on the console, over the login prompt; nscd logs via syslog with
    LOG_CONS, so `logfile` in nscd.conf doesn't help): the base system had
    none. `CAULDRON_SYS_LOGGER` (config/sys.conf) adds one to the sys spells:
    metalog by default (what `/etc/sysconfig/facilities` already names,
    `syslog=smgl-metalog`), `none` with `CAULDRON_SYS_INIT=systemd`
    (journald). The grimoire's sysklogd is 1.5 (2007). opendoas, which
    hard-depends on SYSTEM-LOGGER, becomes installable.
  - **smgl-devel-20261102** (669 MiB, sha512 135f2ce8c4b0...): full install
    walkthrough in QEMU, UEFI and BIOS, passed with every fix above in
    use: efivarfs mounted automatically (efibootmgr works on the live
    system; grub-install via `enchantment chroot` creates its boot entry),
    `/boot/efi` stays mounted after chroot exits, `enchantment hostname`,
    sudo/vim/openssh caches, mkfs.vfat from dosfstools. Installed system:
    no console warnings at boot (nscd now logs to metalog, which starts in
    runlevel S and writes /var/log/everything/current), ping as a user,
    user in wheel, fsck.vfat, sshd init script installed but disabled,
    scribe GRIMOIRE metadata. Only QEMU-specific: "hwclock: select() to
    /dev/rtc ... timed out" under TCG. Note: on terminals shorter than a
    step text (e.g. 80x25, serial), `todo`/`next` and the login welcome
    open in less (q quits); `select caches` opens the dialog menu.
  - `help disks` (alias `guide disks`, paged with `less -XFR`): layout,
    ext4/XFS/btrfs compared, btrfs with subvolumes (@, @home, @log,
    @snapshots, @swap; commands verified on a scratch image with the live
    system's btrfs-progs), swap sizing and swap files, wiping a used disk (old filesystems still
    show in `lsblk -f` after repartitioning; `wipefs`, `blkdiscard`). XFS and btrfs are
    built into the ISO kernel now: without an initramfs a root filesystem's
    driver can't be a module. Root on LVM/LUKS/mdadm still can't work
    without an initramfs (the guide says so).
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
    wireless-regdb,wpa_supplicant,openssh,sudo,dosfstools,systemd,dbus,
    policykit}` (see the README there and the team report above). New
    hack files that are spell scripts get their x bit set
    (`cauldron_sorcerous_cauldron_defaults`): sorcery only runs a
    SUB_DEPENDS etc. that is executable ("missing SUB_DEPENDS!" otherwise).
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

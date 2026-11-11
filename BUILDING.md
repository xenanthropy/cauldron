# Building a Source Mage ISO with cauldron

From "I just cloned cauldron" to "I have an ISO", command by command. For how
cauldron works inside, see CLAUDE.md; this file is only the recipe.

The idea: cauldron has to run inside a Source Mage system. You don't need SMGL
installed: you unpack an official SMGL tarball on any Linux machine, chroot into
it, and run cauldron in there. cauldron then makes its own second SMGL tree
(the "build chroot") under /tmp/cauldron, compiles everything in it, and writes
the ISO next to it.

```
your Linux host
└── /srv/smgl                      SMGL tarball, unpacked: you run cauldron here
    ├── root/cauldron              this repository
    └── tmp/cauldron               cauldron's work area
        ├── build/                 the build chroot (compiles spells)
        ├── smgl-devel-YYYYMMDD.x86_64.iso   <- the result
        └── smgl-test-...-basesystem-x86_64.tar.xz   <- the system tarball
```

## What you need

- An x86_64 Linux machine (any distribution), root access.
- **30-40 GB free disk** where you put /srv/smgl.
- Network access over HTTPS (mirror.sobukus.de, kernel.org, github.com and
  the spells' upstream download sites).
- Time: a first build compiles about 170 spells from source (gcc, glibc,
  python, ...): several hours, most of it in the `sys` step. Later builds
  reuse what is already compiled and take much less.
- `tmux` or `screen` on the host is a good idea, so a long step survives a
  closed terminal.

## 1. Set up the SMGL chroot (once)

On your host, as root:

```sh
mkdir -p /srv/smgl && cd /srv/smgl

# the official basesystem tarball and its checksum
T=smgl-test-0.63-20251212_1200-basesystem-x86_64.tar.xz
wget https://mirror.sobukus.de/files/sourcemage/image/official/test/$T
wget https://mirror.sobukus.de/files/sourcemage/image/official/test/$T.sha512
sha512sum $T; cat $T.sha512        # the two sums must be the same

# unpack it (keep the tarball: cauldron uses it again in step 3)
tar -xpf $T -C /srv/smgl
mv $T /srv/smgl/root/

# put cauldron inside it
git clone <cauldron repository URL> /srv/smgl/root/cauldron
```

## 2. Enter the chroot (every time)

On the host, as root. The mounts are needed once per host boot; skip the
`mount` lines if they are still there (`grep /srv/smgl /proc/mounts`).

```sh
mount --rbind /dev  /srv/smgl/dev
mount -t proc  proc /srv/smgl/proc
mount -t sysfs sys  /srv/smgl/sys
cp /etc/resolv.conf /srv/smgl/etc/

chroot /srv/smgl /usr/bin/env -i HOME=/root TERM="$TERM" \
  PATH=/sbin:/bin:/usr/sbin:/usr/bin /bin/bash -l
```

Everything from here on runs **inside** the chroot.

## 3. Build

```sh
cd /root/cauldron

# which tarball to start the build chroot from, and how many CPU threads to
# compile with (leave 1-2 free if you want to use the machine meanwhile)
export CAULDRON_BASEROOT=/root/smgl-test-0.63-20251212_1200-basesystem-x86_64.tar.xz
export CAULDRON_BUILD_JOBS=$(nproc)

./local-exec/cauldron.sh toolchain 2>&1 | tee /root/toolchain.log
./local-exec/cauldron.sh sys       2>&1 | tee /root/sys.log
./local-exec/cauldron.sh iso       2>&1 | tee /root/iso.log
```

Run them one after another and only go on when the previous one ended without
an error. What they do:

| Step | Makes | Time |
|------|-------|------|
| `toolchain` | the build chroot: unpacks the tarball, installs sorcery and the test grimoire, kernel headers | minutes |
| `sys` | compiles the base system and packs it: the system tarball | hours (first time) |
| `iso` | compiles the installer's tools and installable spells, the kernel and initramfs, then the ISO | about an hour or more (first time) |

`./local-exec/cauldron.sh brew` runs all three in one go, if you prefer.

cauldron shouldn't ask anything. If a sorcery question does appear, it takes
the default answer after a timeout.

## 4. The result

Inside the chroot, in /tmp/cauldron (on the host: /srv/smgl/tmp/cauldron):

- `smgl-devel-YYYYMMDD.x86_64.iso` + `.sha512`: the install ISO
- `smgl-test-0.63-YYYYMMDD_HHMM-basesystem-x86_64.tar.xz` + `.sha512`: the
  system tarball (it is also inside the ISO)

Copy them somewhere outside /tmp/cauldron. Check the ISO:

```sh
cd /srv/smgl/tmp/cauldron && sha512sum -c smgl-devel-*.iso.sha512
```

Try it in QEMU on the host (BIOS, then UEFI; the OVMF path differs between
distributions, e.g. /usr/share/ovmf/OVMF.fd or /usr/share/edk2/x64/OVMF.4m.fd):

```sh
qemu-system-x86_64 -enable-kvm -m 2G -cdrom smgl-devel-*.iso
qemu-system-x86_64 -enable-kvm -m 2G -bios /usr/share/ovmf/OVMF.fd \
  -cdrom smgl-devel-*.iso
```

Put it on a USB stick (this erases the stick; check the device name with
`lsblk` first):

```sh
dd if=smgl-devel-YYYYMMDD.x86_64.iso of=/dev/sdX bs=4M oflag=sync status=progress
```

To sign the release files: `gpg --detach-sign FILE` (cauldron can sign the
system tarball itself: `export CAULDRON_SYS_SIGN_KEY=<key id>` before `sys`).

## Building again later

Update cauldron on the host (the SMGL tarball has no git):

```sh
cd /srv/smgl/root/cauldron && git pull
```

then enter the chroot (step 2) and run the steps again:

```sh
cd /root/cauldron
export CAULDRON_BUILD_JOBS=$(nproc)
./local-exec/cauldron.sh sys
./local-exec/cauldron.sh iso
```

Spells that are already compiled are skipped, so this is much quicker than the
first time. `toolchain` only needs running again if the build chroot is gone.

To rebuild one spell anyway (e.g. after changing its options), delete its cache
first, then run the step that uses it:

```sh
rm /tmp/cauldron/build/var/cache/sorcery/SPELL-*
```

To start over completely: `./local-exec/cauldron.sh cleanse`. It deletes all of
/tmp/cauldron, **including the ISO and the tarball**, and everything compiled.

## When something goes wrong

- **A step failed.** Read the end of its log (`/root/sys.log` etc.). Fix the
  cause, then run the same step again: it continues where it stopped, since
  finished spells are skipped. A spell's own build log is in
  `/tmp/cauldron/build/var/log/sorcery/compile/`.
- **A download failed.** Usually a temporary problem with a mirror: run the
  step again. If one spell's source URL is dead, put the file into
  `/tmp/cauldron/build/var/spool/sorcery/` by hand and run the step again.
- **You stopped a step (Ctrl-C) or it crashed.** Check for leftover mounts
  before doing anything else:

  ```sh
  grep /tmp/cauldron /proc/mounts
  ```

  Unmount each one listed, deepest first (`umount -R <path>`), until the grep
  shows nothing. **Never delete /tmp/cauldron while anything is still mounted
  there**: the build chroot's /dev is the real /dev of your host, and deleting
  it would wipe your device files. (`cleanse` refuses in that case.)
- **Looking around in the build chroot:** `./local-exec/cauldron.sh chroot`
  opens a shell in it with everything mounted (and unmounted again when you
  leave). `./local-exec/cauldron.sh config CAULDRON_TMP` shows any setting.

## Leaving

`exit` the chroot. To remove the host mounts (or just reboot):

```sh
umount -R /srv/smgl/dev /srv/smgl/proc /srv/smgl/sys
```

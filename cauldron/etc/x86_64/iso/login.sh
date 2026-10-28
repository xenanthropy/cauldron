#!/bin/bash
# Login program for the live ISO's ttys (agetty -n -l /bin/login.sh): log in
# as root without a password; the login shell's profile then starts the
# installer (see /etc/profile.d/enchantment.sh).
exec /bin/login -f root

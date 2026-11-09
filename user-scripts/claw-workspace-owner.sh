#!/bin/bash
# Schedule: At Startup of Array.
#
# OpenClaw runs as node (uid 1000) and fchmods its workspace directory, which
# needs ownership. Something on the Unraid side (not Docker Safe New Perms --
# the share is excluded there, and only the root ever flips) resets the claw
# share's root directory to nobody:users, and dreaming then fails with EPERM.
# The contents keep uid 1000, so only the root needs fixing.

chown 1000:1000 /mnt/user/claw
ls -ld /mnt/user/claw

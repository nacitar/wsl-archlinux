#!/bin/bash

error_messages=()
positional_arguments=()

while (($#)); do
  while [[ "${1}" =~ ^-[^-]{2,}$ ]]; do
    # split out multiflags
    set -- "${1::-1}" "-${1: -1}" "${@:2}"
  done
  case "${1}" in
    -m | --update-mirrorlist) UPDATE_MIRRORLIST=1 ;;
    --argument-check) ARGUMENT_CHECK=1 ;;
    -*) error_messages+=("unsupported flag: ${1}") ;;
    *) positional_arguments+=("${1}") ;;
  esac
  shift
done
if [[ "${#positional_arguments[@]}" -ne 1 ]]; then
  error_messages+=("must specify exactly one positional argument for the rootfs directory")
fi
rootfs_directory="${positional_arguments[0]}"
if [[ "${#error_messages[@]}" -gt 0 ]]; then
  printf "%s\n" "${error_messages[@]}" >&2
  exit 1
fi
if [[ "${ARGUMENT_CHECK}" -eq 1 ]]; then
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo 'script must be run as root' >&2
  exit 1
fi

# exit upon error
set -e

cleanup=() # function names appended to this will be called in reverse order
cleanup() {
  for ((i = ${#cleanup[@]} - 1; i >= 0; i--)); do
    "${cleanup[i]}"
  done
}
trap 'cleanup' EXIT
trap 'exit' INT

if [[ ! -d "${rootfs_directory}" ]]; then
  echo "root directory does not exist: ${rootfs_directory}" >&2
  exit 1
fi

# the container was missing this on 9/17/2020, but it may exist later
# avoids error: "mount: /mnt/rootfs/dev/shm: mount point is a symbolic link to nowhere."
if [[ ! -d /run/shm ]]; then
  mkdir /run/shm &>/dev/null
fi

echo ''
echo 'Updating package db and pacman itself...'
pacman -Sy --noconfirm --needed pacman
if [[ "${UPDATE_MIRRORLIST}" -eq 1 ]]; then
  echo ''
  echo 'Installing reflector...  Likely to be slow as the mirror list has not yet been updated...'
  pacman -S --noconfirm --needed reflector
  echo ''
  echo 'Using reflector to generate an optimal mirror list...  Messages about timeouts are normal.'
  # select the 20 most recently synchronized HTTPS mirrors, sorted by download speed; these will be copied by pacstrap
  reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
fi
echo ''
echo 'Installing pacstrap...'
pacman -S --noconfirm --needed arch-install-scripts
echo ''
# The archlinux:latest image at the time of writing has a lot of NoExtract entries
# which remove tons of files, including man pages.  Remove those lines and use a
# new config file for pacstrap so we get everything.
temp_pacman_conf="$(mktemp '/tmp/pacman_conf_filtered.XXXXXXXXXX')"
remove_temp_pacman_conf() {
  if [[ -e "${temp_pacman_conf}" ]]; then
    rm "${temp_pacman_conf}"
  fi
}
cleanup+=(remove_temp_pacman_conf)
sed 's/^\s*NoExtract\s*=.*$//g' /etc/pacman.conf > "${temp_pacman_conf}"
echo 'Running pacstrap (without copying pacman keyring)...'
pacstrap -C "${temp_pacman_conf}" -G "${rootfs_directory}" base

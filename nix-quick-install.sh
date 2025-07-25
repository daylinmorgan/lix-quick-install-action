#!/usr/bin/env bash

set -eu
set -o pipefail

case "$(uname -m)" in
  x86_64)
    arch="x86_64"
    ;;
  arm64)
    arch="aarch64"
    ;;
  aarch64)
    arch="aarch64"
    ;;
  *)
    echo >&2 "unsupported architecture: $(uname -m)"
    exit 1
esac

case "$OSTYPE" in
  darwin*)
    sys="$arch-darwin"
    ;;
  linux*)
    sys="$arch-linux"
    ;;
  *)
    echo >& "unsupported OS type: $OSTYPE"
    exit 1
esac

# Enable KVM on Linux so NixOS tests can run quickly.
# Do this early in the process so lix installation detects the KVM feature.
enable_kvm() {
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-install-lix-action-kvm.rules
  sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=kvm
}
if [[ ("$sys" =~ .*-linux) && ("$ENABLE_KVM" == 'true') ]]; then
  enable_kvm && echo 'Enabled KVM' || echo 'KVM is not available'
fi

# Make sure /nix exists and is writeable
if [ -a /nix ]; then
  if ! [ -w /nix ]; then
    echo >&2 "/nix exists but is not writeable, can't set up lix-quick-install-action"
    exit 1
  else
    rm -rf /nix/var/lix-quick-install-action
  fi
elif [[ "$sys" =~ .*-darwin ]]; then
  disk=$(/usr/bin/stat -f "%Sd" /)
  disk=${disk%s[0-9]*}
  sudo $SHELL -euo pipefail << EOF
  echo nix >> /etc/synthetic.conf
  echo -e "run\\tprivate/var/run" >> /etc/synthetic.conf
  /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -B &>/dev/null \
    || /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t &>/dev/null \
    || echo "warning: failed to execute apfs.util"
  diskutil apfs addVolume "$disk" APFS nix -mountpoint /nix
  mdutil -i off /nix
  chown $USER /nix
EOF
else
  sudo install -d -o "$USER" /nix
  if [[ "$LIX_ON_TMPFS" == "true" || "$LIX_ON_TMPFS" == "True" || "$LIX_ON_TMPFS" == "TRUE" ]]; then
    sudo mount -t tmpfs -o size=90%,mode=0755,gid="$(id -g)",uid="$(id -u)" tmpfs /nix
  fi
fi

# Fetch and unpack lix archive
if [[ "$sys" =~ .*-darwin ]]; then
  # MacOS tar doesn't have the --skip-old-files, so we use gtar
  tar=gtar
else
  tar=tar
fi
rel="$(head -n1 "$RELEASE_FILE")"
url="${LIX_ARCHIVES_URL:-https://github.com/canidae-solutions/lix-quick-install-action/releases/download/$rel}/lix-$LIX_VERSION-$sys.tar.zstd"

echo >&2 "Fetching lix archives from $url"
case "$url" in
  file://)
    "$tar" --skip-old-files --strip-components 1 -x -I unzstd -C /nix "${url#file://}"
    ;;
  *)
    curl -sL --retry 3 --retry-connrefused "$url" \
      | "$tar" --skip-old-files --strip-components 1 -x -I unzstd -C /nix
    ;;
esac

# Setup nix.conf
LIX_CONF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$LIX_CONF_FILE")"
touch "$LIX_CONF_FILE"

# Setup GitHub access token
if [[ -n "${GITHUB_ACCESS_TOKEN:-}" ]]; then
  echo >>"$LIX_CONF_FILE" \
    "access-tokens = github.com=$GITHUB_ACCESS_TOKEN"
fi

# Setup Flakes
echo >>"$LIX_CONF_FILE" \
  "experimental-features = nix-command flakes"
echo >>"$LIX_CONF_FILE" \
  "accept-flake-config = true"

if [ -n "${LIX_CONF:-}" ]; then
  printenv LIX_CONF > "$LIX_CONF_FILE"
fi

# Populate the nix db
lix="$(readlink /nix/var/lix-quick-install-action/lix)"
retries=2
while true; do
  "$lix/bin/nix-store" \
    --load-db < /nix/var/lix-quick-install-action/registration && break || true
  ((retries--))
  echo >&2 "Retrying Nix DB registration"
  sleep 2
done


# Install lix in profile
MANPATH= . "$lix/etc/profile.d/nix.sh"
"$lix/bin/nix-env" -i "$lix"

# Certificate bundle is not detected by nix.sh on macOS.
if [ -z "${NIX_SSL_CERT_FILE:-}" -a -e "/etc/ssl/cert.pem" ]; then
  NIX_SSL_CERT_FILE="/etc/ssl/cert.pem"
fi

# Set env
echo "$HOME/.nix-profile/bin" >> $GITHUB_PATH
echo "NIX_PROFILES=/nix/var/nix/profiles/default $HOME/.nix-profile" >> $GITHUB_ENV
echo "NIX_USER_PROFILE_DIR=/nix/var/nix/profiles/per-user/$USER" >> $GITHUB_ENV
echo "NIX_SSL_CERT_FILE=$NIX_SSL_CERT_FILE" >> $GITHUB_ENV

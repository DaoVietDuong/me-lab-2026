#!/usr/bin/env bash
# Installs the default-deny hub firewall (run from Windows Git Bash, after 20-vms.ps1).
# Safe to re-run. If the new rules lock out SSH, the hub rolls back by itself after 60 s.
set -euo pipefail
cd "$(dirname "$0")/hub"
HUB=lab@10.0.0.2
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

$SSH $HUB 'rm -rf /tmp/labfw && mkdir /tmp/labfw'
scp -q nftables.conf fw-mode-normal.nft fw-mode-pentest.nft egress.conf lab-dns.conf lab-fw $HUB:/tmp/labfw/

$SSH $HUB 'set -e; cd /tmp/labfw
  sudo install -m 0644 fw-mode-normal.nft fw-mode-pentest.nft /etc/lab/
  [ -e /etc/lab/fw-mode.nft ] || sudo ln -s /etc/lab/fw-mode-normal.nft /etc/lab/fw-mode.nft
  sudo install -m 0644 egress.conf /etc/dnsmasq.d/egress.conf
  sudo install -m 0644 lab-dns.conf /etc/dnsmasq.d/lab-dns.conf
  sudo install -m 0755 lab-fw /usr/local/sbin/lab-fw
  sudo dnsmasq --test
  sudo install -m 0755 nftables.conf /etc/nftables.conf.new
  sudo nft -c -f /etc/nftables.conf.new
  sudo mv /etc/nftables.conf.new /etc/nftables.conf
  sudo rm -f /etc/lab/nftables.conf   # the temporary allow-all from first boot
  sudo lab-fw apply --guard'

# A fresh connection proves admin SSH still works under the new rules
$SSH $HUB 'sudo lab-fw confirm'
$SSH $HUB 'sudo lab-fw status'

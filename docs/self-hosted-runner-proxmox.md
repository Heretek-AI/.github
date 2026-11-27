# Optional Self-Hosted CI Runner (`stx-halo` / Proxmox VE)

This runbook documents how to harden and connect a Proxmox VE host (such as the Minisforum MS-S1 Max Strix Halo running LXC 102 `stx-halo`) as an **optional, auto-fallback** GitHub Actions runner for `Heretek-AI`.

## 1. Hardened `/etc/pve/lxc/102.conf`

Remove `lxc.cgroup2.devices.allow: a`, empty `lxc.cap.drop:`, and unused USB/serial mounts, enable `firewall=1` on `net0`, and allow only the minimal character devices plus `/dev/dri` and `/dev/kfd` for ROCm:

```ini
arch: amd64
cores: 16
features: nesting=1
hostname: stx-halo
memory: 32768
net0: name=eth0,bridge=vmbr0,firewall=1,hwaddr=BC:24:11:8B:25:6B,ip=dhcp,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-102-disk-0,size=200G
swap: 512
tags: ci;community-script;rocm
timezone: America/Adak
lxc.prlimit.memlock: unlimited
lxc.cgroup2.devices.deny: a
lxc.cgroup2.devices.allow: c 1:3 rwm
lxc.cgroup2.devices.allow: c 1:5 rwm
lxc.cgroup2.devices.allow: c 1:7 rwm
lxc.cgroup2.devices.allow: c 1:8 rwm
lxc.cgroup2.devices.allow: c 1:9 rwm
lxc.cgroup2.devices.allow: c 5:0 rwm
lxc.cgroup2.devices.allow: c 5:2 rwm
lxc.cgroup2.devices.allow: c 136:* rwm
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 511:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
```

> **Long-term recommendation:** Migrate LXC 102 to an **unprivileged LXC** (`unprivileged: 1` with `render`/`video` GID mapping) or a **KVM VM** for full kernel isolation.

## 2. Proxmox Firewall (`/etc/pve/firewall/102.fw`)

Ensure Datacenter firewall is enabled in Proxmox and add `/etc/pve/firewall/102.fw` to block all LAN/RFC1918 and Proxmox management access from the runner:

```ini
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[RULES]
OUT DROP -dest 10.0.0.0/8
OUT DROP -dest 172.16.0.0/12
OUT DROP -dest 192.168.0.0/16
OUT DROP -dest 169.254.0.0/16
OUT ACCEPT -p udp -dport 53
OUT ACCEPT -p tcp -dport 53
OUT ACCEPT -p tcp -dport 443
OUT ACCEPT -p tcp -dport 80
```

Restart LXC 102 after applying both files (`pct reboot 102`), then verify inside the container:

```bash
curl -fsSL -m 3 https://api.github.com/zen         # Must succeed
curl -m 3 -k https://<proxmox-host-ip>:8006        # Must time out / fail
ls /dev/nvme* /dev/sd* 2>&1                        # Must not be accessible
```

## 3. Runner Labels, Local Caches & Read-Only Probe Token

1. **Register the runner at the org level (`https://github.com/Heretek-AI`)** as a non-root `runner` user (no passwordless `sudo`) with labels:
   `stx-halo,rocm,gfx1151`
2. **Enable shared local NVMe caches** in the runner `.env` file:
   ```dotenv
   SCCACHE_DIR=/var/cache/heretek-ci/sccache
   UV_CACHE_DIR=/var/cache/heretek-ci/uv
   BUN_INSTALL_CACHE_DIR=/var/cache/heretek-ci/bun
   ```
3. **Create a minimal-scope `RUNNER_PROBE_TOKEN` org secret** (visibility: `all`) with **ONLY `Organization self-hosted runners: Read-only`** permission. Never reuse `ORG_SYNC_TOKEN`.
4. **In GitHub Org Settings -> Actions -> General**, enable **"Require approval for all outside collaborators"** before enabling `allows_public_repositories` on the runner group.

## 4. Calling `resolve-runner.yml` from a Repository Workflow

```yaml
jobs:
  resolve-runner:
    uses: Heretek-AI/.github/.github/workflows/resolve-runner.yml@<commit sha> # main
    with:
      preferred_label: stx-halo
    secrets:
      RUNNER_PROBE_TOKEN: ${{ secrets.RUNNER_PROBE_TOKEN }}

  build:
    needs: [resolve-runner]
    runs-on: ${{ fromJson(needs.resolve-runner.outputs.runs_on) }}
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
      - run: echo "Running on self_hosted=${{ needs.resolve-runner.outputs.is_self_hosted }}"
```

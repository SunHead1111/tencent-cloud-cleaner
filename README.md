# Tencent Cloud Cleaner

One-script solution to completely remove **all** Tencent Cloud monitoring agents and tracking components from your CVM/Lighthouse server.

## What it removes

- **Stargate (sgagent)** + **Barad Agent** - cloud monitoring
- **YunJing (YDService / YDLive)** - host security / intrusion detection
- **TAT Agent** - remote command execution channel
- **cloud-init** - metadata-based provisioning
- **cosfs** - COS FUSE mount
- **`/etc/ld.so.preload` injection** - `libonion.so` / `libsgmon.so` global preload hooks (missed by most guides)
- All associated crontabs, systemd services, and self-healing mechanisms

## What it fixes

- DNS -> Alibaba (223.5.5.5) + DNSPod + Google
- NTP -> Alibaba NTP + cn.ntp.org.cn + NTSC
- Package repos -> Tsinghua University mirrors (TUNA)

## Supported OS

- OpenCloudOS 9 / TencentOS / CentOS / RHEL-based
- Debian 12 / Ubuntu

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/yuwan027/tencent-cloud-cleaner/main/clean_tencent.sh | bash
```

Or manually:

```bash
wget -O clean_tencent.sh https://raw.githubusercontent.com/yuwan027/tencent-cloud-cleaner/main/clean_tencent.sh
chmod +x clean_tencent.sh
./clean_tencent.sh
```

## License

MIT

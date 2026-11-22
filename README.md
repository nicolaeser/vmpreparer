# vmpreparer

Turns upstream Debian and Ubuntu cloud images into qcow2 images for Proxmox VE. Cloud-init defaults and the SSH policy are baked in with libguestfs. Run it on Linux with `/dev/kvm`.

Pull the published image:

```bash
docker compose up -d
```

Build from this directory instead:

```bash
docker compose -f docker-compose.dev.yml up -d --build
```

`config/images.conf` lists one `name=url` per line. A line starting with `#` is commented out. Each image is built once per variant in `BUILD_VARIANTS` (default `password sshkey`), as `name-variant.qcow2`.

`images.conf` decides what is served. On every start and every build, images and `images.json` entries that aren't in it, or whose variant isn't in `BUILD_VARIANTS`, are removed. On start only the missing images are built. The scheduled build (`REGENERATE_SCHEDULE`, default `03:00`) downloads every listed image fresh and rebuilds it.

Finished images land in `./output/`. Put that directory behind a web server that only answers for your own IP addresses. `examples/Caddyfile` is a starting point. List the addresses once in `examples/allowed-ips.caddy`.

`client/puller.sh` stays in the repository. Copy it onto the Proxmox node, then point it at that web server:

```bash
chmod +x puller.sh && ./puller.sh
```

It asks for the firmware: SeaBIOS, or UEFI (OVMF, q35) for GPU passthrough. Either way the cloud-init drive goes on SCSI rather than IDE, because OVMF doesn't reliably see an IDE CD-ROM.

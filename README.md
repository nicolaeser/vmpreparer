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

Finished images land in `./output/`. Put that directory behind a web server that only answers for your own IP addresses. `examples/Caddyfile` is a starting point. List the addresses once in `examples/allowed-ips.caddy`.

`client/puller.sh` stays in the repository. Copy it onto the Proxmox node, then point it at that web server:

```bash
chmod +x puller.sh && ./puller.sh
```

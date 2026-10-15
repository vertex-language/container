# container

A container engine for Vertex: run [OCI images](../oci) as Linux containers
on every platform. It is the layer between `oci` (images: pull, store, merge,
build) and `vm` (machines: CPUs, memory, devices), and owns the things
neither should: what a container *is*, its lifecycle, its network, its
volumes, and how it is isolated on each host.

> **Status: started.** The VM backend exists and runs here as `container/virt`
> (moved out of `vm`): `container run <image> [cmd]` boots an image from the
> oci store as a Linux VM, and `container build` builds a Dockerfile with
> each `RUN` in a VM. Everything else below is the proposal it grows into.

```
 container CLI                      run · create · start · stop · ps · exec · logs · rm
                                    build · pull · push · images        (oci underneath)
═══════════════════════════════════════════════════════════════════════════════════
 container          Engine: lifecycle, state on disk, logs, exec, healthchecks
 container/runtime  one Runtime interface, one backend per way of isolating
═══════════════════════════════════════════════════════════════════════════════════
 backend linux      namespaces + cgroups v2 + pivot_root       (Linux hosts, native)
 backend vm         a Linux guest from vm, container run inside (macOS; any host, --vm)
 backend windows    Windows's own container support (via HCS) (Windows hosts)
═══════════════════════════════════════════════════════════════════════════════════
 oci                images, store, rootfs merge, Dockerfile build
 vm                 hypervisor, devices, user-space NAT
```

## How a container runs, per host

| Host | Default | With `--vm` |
| :--- | :--- | :--- |
| **Linux** | **Native.** The image's tree is the root (overlay mount of the layers, or a merged directory), in new user, mount, PID, UTS, IPC and network namespaces, limited by a cgroup, with a dropped capability set and a seccomp filter. No VM, no daemon. | A microVM from `vm` on KVM: stronger isolation, same image. |
| **macOS** | **A Linux VM under the hood.** macOS has no namespaces, so the engine starts a small Linux guest with `vm` (Hypervisor.framework) and runs the container natively *inside* it, with the same `linux` backend the Linux host uses, driven through a guest agent. The user sees containers, not the VM. | One VM per container instead of one shared. |
| **Windows** | **The `windows` backend**, on Windows's own container service (the Host Compute Service). Windows images run as Windows containers; Linux images go through a Linux utility VM that Windows manages. | The `vm` backend, as on macOS, when Windows's own Linux support isn't wanted or available. |

The fun part: **`--vm` is a backend, not a platform feature**, so a Linux
container runs the same way on any host that `vm` runs on. The default is
only the cheapest isolation each host offers; it is never the only one.

One image, one command, anywhere:

```bash
container run alpine:3.20 uname -a        # Linux: a namespace; macOS: inside the VM
container run --vm alpine:3.20 uname -a   # always its own VM, on any host
```

### The shared VM (macOS, and `--vm` off Linux)

The first `container run` starts one VM (`container machine`), kept warm for
later runs and stopped when idle; containers in it are separate namespaces,
exactly as on Linux, so they start in milliseconds. `--vm` asks for a VM of
the container's own instead, booted from the image's tree as its initramfs
(what `container/virt` does today), for when the VM is the isolation boundary.

The guest runs `container-agent` as PID 1's child: it takes commands over
virtio-vsock (create, start, signal, exec, resize the terminal, stream
logs, report status) and is the Linux backend with a socket in front of it.

## Packages (proposed)

| Package | What it does |
| :--- | :--- |
| **`container`** | `Engine`: `Create`, `Start`, `Stop`, `Kill`, `Remove`, `Exec`, `Logs`, `Inspect`, `List`, `Wait`. A container's state (config, status, exit code, timestamps) is a directory under `$VERTEX_CONTAINER_ROOT` or `vertex/container` in the user's data directory, so the CLI needs no daemon and a crashed engine loses nothing. |
| **`container/spec`** | What a container is: the OCI [runtime-spec](https://github.com/opencontainers/runtime-spec) `config.json` (process, root, mounts, namespaces, cgroup limits, capabilities, seccomp), and `FromImage(image, options)` which turns an `oci/spec.Config` (entrypoint, cmd, env, workdir, user, volumes, stop signal, healthcheck) plus the run's flags into one. Every backend takes the same `spec`. |
| **`container/runtime`** | The `Runtime` protocol: `Create(spec)`, `Start`, `Signal`, `Exec`, `State`, `Delete`. The engine picks a backend by host and flags. |
| **`container/linux`** | The native backend. `unshare` the namespaces, map uids (user namespace; rootless by default), mount the root (`overlay` of the oci layers, or `rootfs.DirSink` where overlay isn't allowed), `/proc`, `/sys`, `/dev`, `/dev/pts`, `/dev/shm`, mask paths, `pivot_root`, set up cgroups v2 (memory, CPU, pids), drop capabilities, load the seccomp filter, set the user, `exec`. Needs `os` to expose the syscalls; anything missing is added to `os`, not worked around here. |
| **`container/virt`** | **Exists.** The VM backend (named `virt`, not `vm`, so a program can import it beside `vm`): `Prepare`, `Run`, `VmExecutor`. Boots Alpine's kernel and initramfs from `oci/fetch`, gives the guest the image's tree (initramfs, or a virtio-blk/virtiofs volume for big images), starts `container-agent`. `Machine` is the shared VM; `Dedicated` is the one-per-container form. |
| **`container/agent`** | What runs in the guest: the vsock server and the `linux` backend behind it. Built for linux/arm64 and linux/amd64 and shipped as an `oci/fetch` artifact, so a host needs no Linux toolchain. |
| **`container/windows`** | The native Windows backend, the counterpart of `container/linux`: it speaks the Host Compute Service (compute systems, layers, networking, utility VM for Linux) and keeps that detail inside this package. |
| **`container/network`** | Networks as Docker has them: `bridge` (a bridge, veth pairs, NAT; on Linux native, in the guest elsewhere), `host`, `none`; `-p host:container` publishing; names resolve between containers on one network. Outside Linux, publishing goes host → guest through `vm`'s user-space NAT. |
| **`container/volume`** | `-v host:container` bind mounts, named volumes (a directory in the state root), `tmpfs`, and image `VOLUME`s. To a VM guest, host directories are shared over virtiofs (or 9p until `vm` has virtiofs). |
| **`container/health`** | Runs an image's `HEALTHCHECK` (`oci/spec.Config.Healthcheck`) on its interval; `starting`, `healthy`, `unhealthy` in `inspect` and `ps`. |
| **`container/log`** | Container stdout/stderr as a JSON-lines file with rotation; `logs -f`; a terminal (pty) mode for `-t`. |
| **`container/build`** | `oci/build`'s `Executor` on top of the engine: each `RUN` is a short-lived container, so builds use whichever backend the host has. `RUN --mount` (cache, bind, secret, tmpfs) lands here because it needs volumes. |

## The `container` command

```bash
vsc build -o ./container ./cmd/container
codesign --entitlements ../vm/entitlements.plist --force -s - ./container   # the hypervisor entitlement

container run alpine:3.20                          # interactive shell
container run -it --rm -v $PWD:/src -w /src alpine:3.20 sh
container run -d --name web -p 8080:80 nginx       # detached
container run --vm --memory 2g --cpus 2 python:3.12-slim python -V

container ps [-a]
container logs [-f] web
container exec -it web sh
container stop web && container rm web
container inspect web

container machine start | stop | status            # the shared VM (macOS)

container pull | push | images | rmi               # oci's, under one command
container build -t myapp:1 ./myapp                 # Dockerfile; RUNs are containers
```

Flags follow `docker run` where there is a Docker flag for it, so
muscle memory and existing scripts keep working: `-d`, `-it`, `--rm`,
`--name`, `-e`, `--env-file`, `-v`, `-p`, `-w`, `-u`, `--entrypoint`,
`--memory`, `--cpus`, `--network`, `--platform`, `--read-only`,
`--cap-add/--cap-drop`, `--privileged` (Linux native only).

## Isolation, honestly

- **Linux native** isolates with the kernel's namespaces and cgroups: it is
  as strong as the kernel and the seccomp/capability profile. Rootless by
  default (user namespace); `--privileged` and some `--cap-add`s need root.
- **VM backends** add a hypervisor boundary. The shared VM isolates containers
  *from the host* by VM, and *from each other* by namespaces; `--vm` makes
  the VM the boundary between containers too.
- **Images are architecture-bound.** An arm64 host runs `linux/arm64` images;
  other platforms need an emulator, which this repo doesn't ship.

## Where things live

Each repo has one job:

| Repo | Job |
| :--- | :--- |
| `vm` | Machines only: hypervisor, CPUs, memory, devices, NAT, boot, `vm-run --kernel/--initrd/--disk/--iso/--display`. It knows nothing of images or containers. |
| `oci` | Docker images only: pull, store, merge, build, push. It never runs anything; `oci/build` takes an `Executor`, and `container/virt` is the one that runs `RUN`s. |
| `vmimage` | VM disk images from vendors. |
| `container` | This engine. |

Moved here from `vm`: `vm/container` is `container/virt`; `vm-run --image NAME -- cmd`
is `container run NAME cmd`; `vm-build` is `container build`. Guest-side USER
handling, `su`-based today, moves into `container/agent`, where it is a real
`setuid` before `exec`. The pinned Alpine kernel and busybox still come from
`oci/fetch`; they move into this repo when `container/agent` replaces busybox.

## Roadmap

1. **Done:** `container/virt` and `container run` / `container build` (image as
   a VM, USER, env, workdir, NAT). **Next:** `spec` and state on disk, with
   `ps`/`logs`/`rm`.
2. **`container/agent` + the shared VM**: `exec`, `stop`, detached runs,
   many containers in one VM; macOS default.
3. **`container/linux`**: the native backend; rootless; cgroups; seccomp.
4. **`network`, `volume`, `health`**: `-p`, `-v`, `VOLUME`, `HEALTHCHECK`.
5. **`container/build`**: `RUN --mount`; the Executor moves out of `container/virt`.
6. **`container/windows`**: Windows.

Compose-style multi-container files, a Docker-compatible socket API, image
signing and registries *served* by the engine are out of scope for now.

## License

See [LICENSE](LICENSE).

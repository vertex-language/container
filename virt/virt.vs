// Package virt is container's VM backend: it boots a container image from the oci store as a
// Linux VM: the image's merged tree is the VM's root filesystem, held in
// memory as its initramfs, and the image's command is what runs.
//
//     let status = try await virt.Run(virt.Options(image: "alpine:3.20"))
//
// What it boots with comes from oci/fetch, pinned and checked: Alpine's
// linux-virt kernel, the virtio modules from Alpine's initramfs, and a
// static busybox that brings the system up whatever libc the image has.
// The image's tree is made into a cpio once and kept in the cache; each
// boot adds a small second cpio (/.vertex: busybox, the init script, the
// image's config) which the kernel unpacks over the first.
//
// The guest gets user-space NAT networking (DHCP from the host side),
// the console on the terminal, and powers off when the command exits.
package virt

import (
    "archive/cpio"
    "compress/gzip"
    "archive/tar"
    "fs"
    "io"
    "net/nat"
    "oci/digest"
    "oci/fetch"
    "oci/spec"
    "oci/registry"
    "oci/rootfs"
    "oci/store"
    "os/process"
    "os/user"
    "sync"
    "time"
    "vm"
    "vm/boot"
)

public enum ContainerError: Error, CustomStringConvertible {
    case noCommand(string)
    case missing(string)

    public var description: string {
        switch self {
        case .noCommand(let i): return "\(i) says nothing to run; give a command"
        case .missing(let w): return "boot files incomplete: \(w)"
        }
    }
}

/// How to run an image.
public struct Options {
    /// A name the store knows -- "alpine:3.20" -- or one to pull.
    public var Image: string
    public var MemoryMiB: int = 1024
    public var Cpus: int = 2
    /// Replaces the image's command (its Cmd; the Entrypoint stays,
    /// as `docker run image args…` does).
    public var Args: [string] = []
    /// Replaces the entrypoint and command both.
    public var Entrypoint: [string]? = nil
    /// "KEY=value", added to the image's environment.
    public var Env: [string] = []
    public var WorkingDir: string? = nil
    public var Network: bool = true
    public var Hostname: string? = nil
    /// The oci store; nil is its default root.
    public var StoreRoot: string? = nil
    /// Pull the image if the store doesn't have it.
    public var Pull: bool = true
    /// Extra kernel command line.
    public var KernelArgs: string = ""
    /// Stops the VM after this many seconds; nil lets it run.
    public var TimeoutSec: int? = nil

    public init(image: string) {
        Image = image
    }
}

/// What a VM for an image boots: ready to give vm.
public struct Prepared {
    public var Kernel: [uint8]
    public var Initrd: [uint8]
    public var Cmdline: string
    public var Image: store.Image
    public var Command: [string]
}

/// The modules a guest needs that the kernel doesn't have built in:
/// vm's devices are virtio-mmio, a module in Alpine's linux-virt (virtio's
/// core and its PCI transport are built in).
let modules = ["kernel/drivers/virtio/virtio_mmio.ko", "kernel/net/core/failover.ko", "kernel/drivers/net/net_failover.ko",
               "kernel/drivers/net/virtio_net.ko", "kernel/drivers/block/virtio_blk.ko"]

/// Where image trees made into cpio archives are kept.
func cacheDir() -> fs.Path {
    fs.Path((user.CacheDir() ?? "/tmp") + "/vertex/container/trees")
}

/// Gets everything a boot of `o.Image` needs: the image (pulled if
/// asked), the boot files, the image's tree as a cpio (made once), and
/// this boot's own cpio on top.
public func Prepare(o: Options, progress: (string) -> Void = { _ in }) async throws -> Prepared {
    let st = try store.Store(root: o.StoreRoot)
    var img: store.Image
    if st.Resolve(o.Image) == nil && o.Pull {
        progress("pulling \(o.Image)")
        img = try await registry.Pull(o.Image, into: st)
    } else {
        img = try st.Image(o.Image)
    }

    for f in [fetch.Catalog.alpineKernel, fetch.Catalog.alpineInitramfs, fetch.Catalog.alpineBusybox] {
        if fetch.Path(f, in: st) == nil {
            progress("fetching \(f.Name)")
        }
        try await fetch.Fetch(f, into: st)
    }

    // The image's tree, made once per manifest.
    try fs.CreateDir(cacheDir(), all: true)
    let treePath = cacheDir() / (img.ManifestDigest.Hex + ".cpio")
    if !fs.Exists(treePath) {
        let plan = try rootfs.Merge(img, in: st)
        progress("making \(img.Name)'s tree (\(plan.Count) entries)")
        let tmp = cacheDir() / (img.ManifestDigest.Hex + ".cpio.tmp")
        let sink = try rootfs.CpioSink(path: tmp, plan: plan)
        try plan.Emit(to: sink)
        try fs.Rename(tmp, treePath)
    }

    // What runs: the image's, or what was asked for.
    var command = o.Entrypoint ?? img.Config.Entrypoint
    command += o.Args.isEmpty && o.Entrypoint == nil ? img.Config.Cmd : o.Args
    if command.isEmpty {
        throw ContainerError.noCommand(img.Name)
    }

    let overlay = try bootOverlay(o, img, command, st)
    var initrd = try fs.ReadFile(treePath)
    initrd.append(contentsOf: overlay)

    let raw = try fs.ReadFile(fetch.Path(fetch.Catalog.alpineKernel, in: st)!)
    let kernel = try await boot.UnpackKernel(raw)
    var cmdline = "console=ttyAMA0 rdinit=/.vertex/init panic=-1 quiet loglevel=3"
    if !o.KernelArgs.isEmpty { cmdline += " " + o.KernelArgs }
    return Prepared(Kernel: kernel, Initrd: initrd, Cmdline: cmdline, Image: img, Command: command)
}

/// The VM's configuration for what Prepare made.
public func MakeConfig(p: Prepared, o: Options) -> vm.Config {
    var cfg = vm.Config(cpus: o.Cpus, memory: uint64(o.MemoryMiB) << 20)
    cfg.Boot = .linux(kernel: p.Kernel, initrd: p.Initrd, cmdline: p.Cmdline)
    if o.Network {
        cfg.Network.append(.nat())
    }
    return cfg
}

/// Boots the image with the terminal as its console, and waits for it
/// to power off.
public func Run(o: Options, progress: (string) -> Void = { _ in }) async throws -> vm.ExitStatus {
    let p = try await Prepare(o, progress: progress)
    progress("booting \(p.Image.Name): \(p.Command.joined(separator: " ")) (\(o.Cpus) CPUs, \(o.MemoryMiB) MiB)")
    let machine = try vm.Create(MakeConfig(p, o), consoleWriter: vm.StdioWriter())
    defer { machine.Close() }
    _ = sync.Thread.spawn {
        var stdin = process.Stdin
        var buf = [uint8](repeating: 0, count: 256)
        while true {
            guard let n = try? stdin.Read(into: &buf), n > 0 else { break }
            machine.ConsoleUart?.Feed(Array(buf[0..<n]).map { $0 == 10 ? uint8(13) : $0 })
        }
    }
    try machine.Start()
    if let t = o.TimeoutSec {
        Task {
            try? await time.Sleep(.Milliseconds(int64(t) * 1000))
            print("\n[vertex] stopping after \(t)s")
            machine.Terminate()
        }
    }
    return try await machine.Wait()
}

/// A word quoted for sh: 'it'\''s'.
func shQuote(s: string) -> string {
    var out = "'"
    for c in s {
        if c == "'" {
            out += "'\\''"
        } else {
            out.append(c)
        }
    }
    return out + "'"
}

/// /.vertex and what else this boot needs on top of the image's tree.
/// What a boot's /.vertex/config says.
struct Guest {
    var Env: [string]
    var WorkingDir: string
    var User: string
    var Command: [string]
    var Network: bool
    var Hostname: string
    /// Run once for a build's RUN: the tree goes to /dev/vda afterwards.
    var Build: bool = false
}

func bootOverlay(o: Options, img: store.Image, command: [string], st: store.Store) throws -> [uint8] {
    let host = o.Hostname ?? img.Name.split(separator: "/").last.map { string($0) }?
        .split(separator: ":").first.map { string($0) } ?? "vertex"
    return try overlay(Guest(Env: img.Config.Env + o.Env, WorkingDir: o.WorkingDir ?? img.Config.WorkingDir,
                             User: img.Config.User, Command: command, Network: o.Network, Hostname: host), st)
}

func overlay(g: Guest, st: store.Store) throws -> [uint8] {
    var w = cpio.Writer(io.Cursor())
    func dir(path: string, mode: uint32 = 0o755) throws {
        try w.WriteHeader(cpio.Header(name: path, mode: cpio.ModeType.directory | mode, nlink: 2))
    }
    func file(path: string, data: [uint8], mode: uint32 = 0o755) throws {
        try w.WriteHeader(cpio.Header(name: path, mode: cpio.ModeType.regular | mode, size: int64(data.count)))
        try w.Write(data)
    }
    // Mount points an image may leave out (a scratch-based one has none).
    // Where the image has them the kernel only sets their mode again,
    // which is what they have anyway.
    for d in ["proc", "sys", "dev", "run", "etc"] {
        try dir(d)
    }
    try dir("tmp", mode: 0o1777)
    try dir(".vertex")
    try file(".vertex/busybox", try busybox(st))
    try file(".vertex/init", [uint8](initScript.utf8))

    // The image's configuration, as shell.
    var cfg = ""
    for e in g.Env where e.contains("=") {
        cfg += "export \(shQuote(e))\n"
    }
    cfg += "VERTEX_WORKDIR=\(shQuote(g.WorkingDir))\n"
    cfg += "VERTEX_USER=\(shQuote(g.User))\n"
    cfg += "VERTEX_NET=\(g.Network ? 1 : 0)\n"
    cfg += "VERTEX_MODE=\(g.Build ? "build" : "run")\n"
    // The NAT's addresses are fixed, so they are set rather than asked
    // for: no DHCP client, no AF_PACKET module, no wait.
    // DNS is the gateway's: it asks the host's own nameservers.
    let n = nat.Config.default
    cfg += "VERTEX_ADDR=\(n.Guest)/\(n.Network.Bits)\n"
    cfg += "VERTEX_GATEWAY=\(n.Gateway)\n"
    cfg += "VERTEX_DNS=\(shQuote(n.Dns.description))\n"
    cfg += "VERTEX_HOSTNAME=\(shQuote(g.Hostname))\n"
    cfg += "set -- " + g.Command.map { shQuote($0) }.joined(separator: " ") + "\n"
    // The same command as one string, for `su -c` to parse again.
    cfg += "VERTEX_CMD=\(shQuote(g.Command.map { shQuote($0) }.joined(separator: " ")))\n"
    try file(".vertex/config", [uint8](cfg.utf8), mode: 0o644)

    // The kernel's virtio modules, from Alpine's own initramfs, kept
    // under /.vertex so they are never part of the image's tree.
    try dir(".vertex/modules")
    for (path, data) in try kernelModules(st) {
        try file(".vertex/modules/" + path, data, mode: 0o644)
    }
    try w.Close()
    return w.Inner.Bytes
}

/// bin/busybox.static out of the busybox-static .apk.
func busybox(st: store.Store) throws -> [uint8] {
    guard let p = fetch.Path(fetch.Catalog.alpineBusybox, in: st) else {
        throw ContainerError.missing("busybox")
    }
    var r = tar.Reader(gzip.Reader(try fs.Open(p)))
    while let h = try r.Next() {
        if h.Name == "bin/busybox.static" {
            return try r.ReadAll()
        }
    }
    throw ContainerError.missing("bin/busybox.static in \(p)")
}

/// The modules a guest needs, by file name in the order they load, out
/// of Alpine's initramfs.
func kernelModules(st: store.Store) throws -> [(string, [uint8])] {
    guard let p = fetch.Path(fetch.Catalog.alpineInitramfs, in: st) else {
        throw ContainerError.missing("initramfs")
    }
    var r = cpio.Reader(gzip.Reader(try fs.Open(p)))
    var found: [string: [uint8]] = [:]
    while let h = try r.Next() {
        guard h.Name.hasPrefix("lib/modules/"), h.Kind == cpio.ModeType.regular else { continue }
        for m in modules where h.Name.hasSuffix("/" + m) {
            found[m] = try r.ReadAll()
        }
    }
    var out: [(string, [uint8])] = []
    for m in modules {
        guard let data = found[m] else { throw ContainerError.missing("\(m) in \(p)") }
        out.append((string(m.split(separator: "/").last!), data))
    }
    return out
}

/// PID 1: brings up /proc, /sys, /dev and the network with busybox, then
/// runs the image's command on the console and powers off when it ends.
let initScript = """
#!/.vertex/busybox sh
B=/.vertex/busybox
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TERM=vt100
. /.vertex/config
$B mount -t proc proc /proc
$B mount -t sysfs sysfs /sys
$B mount -t devtmpfs devtmpfs /dev 2>/dev/null
$B mkdir -p /dev/pts /dev/shm /run /tmp /etc
$B mount -t devpts devpts /dev/pts 2>/dev/null
$B mount -t tmpfs tmpfs /dev/shm 2>/dev/null
$B mount -t tmpfs tmpfs /run 2>/dev/null
[ -e /dev/fd ] || $B ln -s /proc/self/fd /dev/fd
$B hostname "$VERTEX_HOSTNAME"
[ -s /etc/hostname ] || echo "$VERTEX_HOSTNAME" > /etc/hostname
grep -q "$VERTEX_HOSTNAME" /etc/hosts 2>/dev/null || printf '127.0.0.1 localhost %s\\n::1 localhost\\n' "$VERTEX_HOSTNAME" >> /etc/hosts
$B ip link set lo up
for m in virtio_mmio virtio_blk failover net_failover virtio_net; do
    $B insmod /.vertex/modules/$m.ko 2>/dev/null
done
if [ "$VERTEX_NET" = 1 ]; then
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /sys/class/net/eth0 ] && break; $B usleep 50000; done
    if $B ip link set eth0 up 2>/dev/null; then
        $B ip addr add "$VERTEX_ADDR" dev eth0
        $B ip route add default via "$VERTEX_GATEWAY" dev eth0
        if [ ! -s /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
            $B rm -f /etc/resolv.conf
            for d in $VERTEX_DNS; do echo "nameserver $d" >> /etc/resolv.conf; done
        fi
    else
        echo "[vertex] no network device"
    fi
fi
# The image's USER: a name or number, and perhaps a group. su takes names
# only, so the user is looked up in /etc/passwd, or made up for a number
# the image doesn't list, and run as under a name of its own.
VERTEX_SU=
case "$VERTEX_USER" in ''|root|0|root:*|0:*) ;; *)
    u=${VERTEX_USER%%:*}
    g=
    case "$VERTEX_USER" in *:*) g=${VERTEX_USER#*:} ;; esac
    ent=$($B awk -F: -v u="$u" '$1==u||$3==u{print $3":"$4":"$6; exit}' /etc/passwd 2>/dev/null)
    if [ -n "$ent" ]; then
        uid=${ent%%:*}; rest=${ent#*:}; gid=${rest%%:*}; home=${rest#*:}
    else
        uid=$u; gid=0; home=/
    fi
    case "$g" in
    '') ;;
    *[!0-9]*) gid=$($B awk -F: -v g="$g" '$1==g{print $3; exit}' /etc/group 2>/dev/null) ;;
    *) gid=$g ;;
    esac
    case "$uid$gid" in
    ''|*[!0-9]*) echo "[vertex] no such user or group: $VERTEX_USER" ;;
    *)
        $B touch /etc/passwd
        echo "vertexrun:x:$uid:$gid::${home:-/}:/bin/sh" >> /etc/passwd
        VERTEX_SU=vertexrun
        ;;
    esac
    ;;
esac
if [ "$VERTEX_MODE" = build ]; then
    # A build's RUN: the command, then the whole tree as a tar onto the
    # big disk and the status onto the small one, for the host to read.
    $B mkdir -p "${VERTEX_WORKDIR:-/}"
    cd "${VERTEX_WORKDIR:-/}"
    if [ -n "$VERTEX_SU" ]; then
        $B su -s /bin/sh "$VERTEX_SU" -c "exec $VERTEX_CMD" </dev/null
    else
        "$@" </dev/null
    fi
    code=$?
    cd /
    out=; status=
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -e /sys/block/vdb ] && break
        $B usleep 100000
    done
    for d in /sys/block/vd*; do
        [ -e "$d" ] || continue
        if [ "$($B cat $d/size)" -le 64 ]; then status=/dev/${d##*/}; else out=/dev/${d##*/}; fi
    done
    $B tar -cf "$out" --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./.vertex . || code=255
    $B sync
    echo "$code" | $B dd of="$status" conv=fsync 2>/dev/null
    $B sync
    $B poweroff -f
fi
cd "${VERTEX_WORKDIR:-/}" 2>/dev/null || cd /
if [ -n "$VERTEX_SU" ]; then
    $B su -s /bin/sh "$VERTEX_SU" -c "exec $B setsid -c $VERTEX_CMD" </dev/ttyAMA0 >/dev/ttyAMA0 2>&1
else
    $B setsid -c "$@" </dev/ttyAMA0 >/dev/ttyAMA0 2>&1
fi
code=$?
echo "[vertex] $1 exited with $code"
$B sync
$B poweroff -f
"""

/// Alpine's linux-virt kernel (unpacked to an Image) and its initramfs,
/// from the oci store, fetched and checked the first time: what vm boots
/// when it is given no kernel of its own.
public func AlpineBootFiles(storeRoot: string? = nil) async throws -> ([uint8], [uint8]) {
    let st = try store.Store(root: storeRoot)
    let k = try await fetch.Fetch(fetch.Catalog.alpineKernel, into: st)
    let i = try await fetch.Fetch(fetch.Catalog.alpineInitramfs, into: st)
    return (try await boot.UnpackKernel(try fs.ReadFile(k)), try fs.ReadFile(i))
}

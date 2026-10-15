package virt

import (
    "crypto/sha256"
    "fs"
    "oci/build"
    "oci/fetch"
    "oci/rootfs"
    "oci/store"
    "vm"
    "vm/boot"
)

/// Runs a Dockerfile's RUN in a VM: oci/build's Executor. The tree so far
/// boots as the VM's root, the command runs with the build's environment,
/// and the guest writes the tree it leaves onto a disk -- a tar, on a
/// raw disk the host reads back -- and its exit status onto another.
public final class VmExecutor: build.Executor {
    public var MemoryMiB: int = 2048
    public var Cpus: int = 2
    public var StoreRoot: string? = nil
    /// How big the disk the tree is written to may grow (it is sparse).
    public var OutputSize: int64 = 16 << 30

    public init(storeRoot: string? = nil) {
        StoreRoot = storeRoot
    }

    public func Run(layers: [rootfs.Layer], env: [string], workdir: string, user: string,
                    command: [string], output: fs.Path) async throws -> int32 {
        let st = try store.Store(root: StoreRoot)
        for f in [fetch.Catalog.alpineKernel, fetch.Catalog.alpineInitramfs, fetch.Catalog.alpineBusybox] {
            try await fetch.Fetch(f, into: st)
        }

        // The tree, made once per stack of layers.
        try fs.CreateDir(cacheDir(), all: true)
        var key = sha256.New()
        for l in layers { key.WriteString(l.Path.Value + "\n") }
        let treePath = cacheDir() / ("layers-" + sha256.ToHex(key.Checksum()) + ".cpio")
        if !fs.Exists(treePath) {
            let plan = try rootfs.Merge(layers)
            let tmp = cacheDir() / (treePath.Name()! + ".tmp")
            let sink = try rootfs.CpioSink(path: tmp, plan: plan)
            try plan.Emit(to: sink)
            try fs.Rename(tmp, treePath)
        }
        var initrd = try fs.ReadFile(treePath)
        initrd.append(contentsOf: try overlay(Guest(Env: env, WorkingDir: workdir, User: user, Command: command,
                                                    Network: true, Hostname: "vertex-build", Build: true), st))

        let raw = try fs.ReadFile(fetch.Path(fetch.Catalog.alpineKernel, in: st)!)
        let kernel = try await boot.UnpackKernel(raw)

        // The disks: the tree's, sparse, and one sector for the status.
        let out = try fs.Create(output)
        try out.SetLength(OutputSize)
        try out.Close()
        let statusPath = fs.Path(output.Value + ".status")
        try fs.WriteFile(statusPath, [uint8](repeating: 0, count: 4096))
        defer { try? fs.Remove(statusPath) }

        var cfg = vm.Config(cpus: Cpus, memory: uint64(MemoryMiB) << 20)
        cfg.Boot = .linux(kernel: kernel, initrd: initrd, cmdline: "console=ttyAMA0 rdinit=/.vertex/init panic=-1 quiet loglevel=3")
        cfg.Network.append(.nat())
        cfg.Storage.append(.disk(try await vm.OpenDisk(output)))
        cfg.Storage.append(.disk(try await vm.OpenDisk(statusPath)))
        let machine = try vm.Create(cfg, consoleWriter: vm.StdioWriter())
        defer { machine.Close() }
        try machine.Start()
        _ = try await machine.Wait()

        // "0\n" and so on: what the command exited with.
        let status = try fs.ReadFile(statusPath)
        var code: int32 = 0
        var digits = 0
        for b in status {
            guard b >= 0x30 && b <= 0x39 else { break }
            code = code * 10 + int32(b - 0x30)
            digits += 1
        }
        if digits == 0 {
            throw ContainerError.missing("the RUN's status: the VM stopped before it finished")
        }
        return code
    }
}

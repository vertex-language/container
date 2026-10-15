// container: run OCI images and build Dockerfiles, on vm.
//
//     container run [--memory MB] [--cpus N] [--env K=V] [--no-net] [--timeout SEC] <image> [cmd...]
//     container build [-t name] [-f Dockerfile] [--build-arg K=V] [--target stage] <context>
//
// This is the VM backend (container/virt): the image boots as a Linux
// guest. The binary needs the hypervisor entitlement, as vm-run does:
//
//     vsc build -o ./container ./cmd/container
//     codesign --entitlements ../vm/entitlements.plist --force -s - ./container
package main

import (
    "oci/build"
    "oci/store"
    "os/process"
    "container/virt"
)

func usage() {
    print("""
Usage: container [--root <dir>] <command> [args]

Commands:
  run [--memory MB] [--cpus N] [--env K=V]... [--no-net] [--timeout SEC] <image> [cmd...]
                                  run an image (pulled if missing) as a VM
  build [-t name] [-f Dockerfile] [--build-arg K=V]... [--target stage]
        [--memory MB] [--cpus N] <context>
                                  build a Dockerfile; each RUN runs in a VM

Images are oci's: `oci pull`, `oci images`, `oci push` manage them.
""")
}

func run(_ args: [string], root: string?) async -> int32 {
    var o: virt.Options? = nil
    var memory: int? = nil
    var cpus: int? = nil
    var env: [string] = []
    var network = true
    var timeout: int? = nil
    var rest: [string] = []
    var i = 0
    while i < args.count && o == nil {
        let a = args[i]
        let next: string? = i + 1 < args.count ? args[i + 1] : nil
        switch a {
        case "--memory":
            memory = int(next ?? "")
            i += 1
        case "--cpus":
            cpus = int(next ?? "")
            i += 1
        case "--env", "-e":
            if let v = next { env.append(v) }
            i += 1
        case "--no-net":
            network = false
        case "--timeout":
            timeout = int(next ?? "")
            i += 1
        default:
            o = virt.Options(image: a)
            rest = Array(args[(i + 1)...])
        }
        i += 1
    }
    guard var opts = o else {
        usage()
        return 2
    }
    if rest.first == "--" { rest.removeFirst() }
    opts.MemoryMiB = memory ?? 1024
    opts.Cpus = cpus ?? 2
    opts.Env = env
    opts.Args = rest
    opts.Network = network
    opts.TimeoutSec = timeout
    opts.StoreRoot = root
    do {
        let status = try await virt.Run(opts) { msg in print("[container] \(msg)") }
        print("\nVM exited: \(status)")
        return 0
    } catch {
        print("container: \(error)")
        return 1
    }
}

func buildCommand(_ args: [string], root: string?) async -> int32 {
    var o = build.Options(context: ".")
    var memory = 2048
    var cpus = 2
    var context: string? = nil
    var i = 0
    while i < args.count {
        let a = args[i]
        let next: string? = i + 1 < args.count ? args[i + 1] : nil
        switch a {
        case "-t", "--tag":
            o.Tag = next
            i += 1
        case "-f", "--file":
            o.Dockerfile = next
            i += 1
        case "--build-arg":
            if let kv = next {
                let parts = kv.split(separator: "=", maxSplits: 1).map { string($0) }
                o.BuildArgs[parts[0]] = parts.count > 1 ? parts[1] : ""
            }
            i += 1
        case "--target":
            o.Target = next
            i += 1
        case "--memory":
            memory = int(next ?? "") ?? memory
            i += 1
        case "--cpus":
            cpus = int(next ?? "") ?? cpus
            i += 1
        default:
            context = a
        }
        i += 1
    }
    o.Context = context ?? "."
    do {
        let st = try store.Store(root: root)
        let ex = virt.VmExecutor(storeRoot: root)
        ex.MemoryMiB = memory
        ex.Cpus = cpus
        let img = try await build.Builder(store: st, executor: ex).Build(o)
        print("built \(img.Name)  \(img.ManifestDigest.Short)")
        return 0
    } catch {
        print("container: \(error)")
        return 1
    }
}

public func main() async -> int32 {
    var args = Array(process.Args.dropFirst())
    var root: string? = nil
    if args.count >= 2 && args[0] == "--root" {
        root = args[1]
        args.removeFirst(2)
    }
    guard let cmd = args.first else {
        usage()
        return 2
    }
    args.removeFirst()
    switch cmd {
    case "run": return await run(args, root: root)
    case "build": return await buildCommand(args, root: root)
    case "help", "--help", "-h":
        usage()
        return 0
    default:
        print("container: unknown command \(cmd)")
        usage()
        return 2
    }
}

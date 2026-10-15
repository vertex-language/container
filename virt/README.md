# container/virt

Container's VM backend: boots a container image from the oci store as a Linux VM. The image's merged tree is the VM's root filesystem, held in memory as its initramfs, and the image's command is what runs; `VmExecutor` runs a Dockerfile's `RUN` steps the same way for `oci/build`.

```vertex
import "container/virt"
```

## Types

- **`ContainerError`** (enum)
- **`Options`** (struct): How to run an image.
- **`Prepared`** (struct): What a VM for an image boots: ready to give vm.
- **`VmExecutor`** (class): Runs a Dockerfile's RUN in a VM: oci/build's Executor.

## Functions

- `func Prepare(_ o: Options, progress:)`: Gets everything a boot of `o.Image` needs: the image (pulled if asked), the boot files, the image's tree as a cpio (made once), and this boot's own cpio on top.
- `func MakeConfig(_ p: Prepared, _ o: Options) -> vm.Config`: The VM's configuration for what Prepare made.
- `func Run(_ o: Options, progress:)`: Boots the image with the terminal as its console, and waits for it to power off.

Part of the [`container`](https://github.com/vertex-language/container) repository.

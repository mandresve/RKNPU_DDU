# Updating the RKNPU Driver to 0.9.8 on Orange Pi (RK3588 / RK3588S boards)

This guide provides detailed instructions to update the RKNPU driver to version 0.9.8 on an Orange Pi 5B (or a similar board) running Jammy 1.0.8 with the Linux 6.1.43-rockchip-rk3588 kernel. Upgrading the RKNPU driver is essential for running RKLLM multimodal models successfully. You can follow this guide for other Orange Pi 5 boards that use the official Orange Pi Ubuntu images.

**This guide walks you through compiling the kernel by hand.** The result is a `linux-image-current-rockchip-rk3588_1.0.8_arm64.deb` package that you can **contribute back to this project**, so that other people with the same Orange Pi board can update their NPU driver with the one-line installer instead of building everything from scratch — see [Contributing your build](#contributing-your-build).

If your board is already supported, you don't need to compile anything: just clone this repository and use the installer described in the main [README](README.md).

You can download working RKLLM models from the Hugging Face links below to run the [examples in the RKNN LLM repository](https://github.com/airockchip/rknn-llm/tree/main/examples):

1. [Qwen2-VL-2B-rkllm](https://huggingface.co/3ib0n/Qwen2-VL-2B-rkllm)
2. [Deepseek R1 1.5B / 7B and Qwen2.5 3B](https://huggingface.co/VRxiaojie)

# Build the Linux 6.1.43 rk3588 kernel with RKNPU driver 0.9.8

## Prerequisites

- **Operating System**: [Ubuntu 22.04 Jammy 6.1.43](https://drive.google.com/drive/folders/1xhP1KeW_hL5Ka4nDuwBa8N40U8BN0AC9)
- **Kernel Version**: Linux 6.1.43-rockchip-rk3588
- **Disk Space**: at least 20 GB of free space
- **Network Access**: make sure the development board has internet access to clone repositories and download the required packages.

## Step 1: Verify the current NPU driver version

Before you start, check the current version of the RKNPU driver:

```bash
sudo cat /sys/kernel/debug/rknpu/version
```

If the output reports a version lower than 0.9.8, continue with the steps below to upgrade the driver.

## Step 2: Install the required dependencies

Make sure your system has the necessary packages installed:

```bash
sudo apt-get update
sudo apt-get install -y git cmake
```

## Step 3: Clone the Orange Pi build repository

The Orange Pi build repository is based on the Armbian build framework and is used to compile the Linux kernel for Orange Pi boards. Clone it:

```bash
cd ~
git clone https://github.com/orangepi-xunlong/orangepi-build.git -b next
```

## Step 4: Download the Linux 6.1 kernel source

Create a directory for the kernel source and move into it:

```bash
cd orangepi-build
mkdir kernel && cd kernel
```

Clone the kernel source code:

```bash
git clone https://github.com/orangepi-xunlong/linux-orangepi.git -b orange-pi-6.1-rk35xx
```

Rename the directory for consistency:

```bash
mv linux-orangepi/ orange-pi-6.1-rk35xx
```

## Step 5: Download and extract the RKNPU driver

Get RKNPU driver version 0.9.8 from the official repository:

```bash
cd ~/orangepi-build
git clone https://github.com/airockchip/rknn-llm.git
```

Extract the driver:

```bash
tar -xvf /rknn-llm/rknpu-driver/rknpu_driver_0.9.8_20241009.tar.bz2
```

Copy the extracted driver files into the kernel source:

```bash
cp -r drivers/ kernel/orange-pi-6.1-rk35xx/
```

## Step 6: Modify the kernel source files

To ensure compatibility and avoid compilation errors, make the following changes:

1. **Modify `kernel/include/linux/mm.h`**

   Edit the file:

   ```bash
   sudo nano kernel/orange-pi-6.1-rk35xx/include/linux/mm.h
   ```

   Add the following code in an appropriate location:

   ```c
   static inline void vm_flags_set(struct vm_area_struct *vma, vm_flags_t flags)
   {
       vma->vm_flags |= flags;
   }
   static inline void vm_flags_clear(struct vm_area_struct *vma, vm_flags_t flags)
   {
       vma->vm_flags &= ~flags;
   }
   ```

   ![image](https://github.com/user-attachments/assets/adcb44bc-15b9-41bd-bd53-72273c06d021)

2. **Modify `rknpu_devfreq.c`**

   Edit the file:

   ```bash
   sudo nano kernel/orange-pi-6.1-rk35xx/drivers/rknpu/rknpu_devfreq.c
   ```

   On line 242, comment out `.set_soc_info = rockchip_opp_set_low_length,`:

   ```c
   //.set_soc_info = rockchip_opp_set_low_length,
   ```

   ![image](https://github.com/user-attachments/assets/26e01e59-d2b1-4f29-b997-f171b998ec8f)

## Step 7: Disable source synchronization

Because we manually overwrote the driver files in the `kernel/orange-pi-6.10-rk35xx` directory earlier, running the compilation directly now would make the script detect an inconsistency with the upstream source code and re-pull it, overwriting our changes. To prevent that, disable source-code synchronization in the configuration file.

First, run `build.sh` once to initialize it:

1. Run the build script to initialize:

   ```bash
   sudo ./build.sh
   ```

   Wait a moment, and when the selection menu appears, use the → arrow key and the Enter key to exit the menu.

   Check the current directory again: you will find a new `userpatches` folder that contains the configuration files.

2. Edit the `config-default.conf` file:

   ```bash
   sudo nano userpatches/config-default.conf
   ```

3. Find `IGNORE_UPDATES` and set it to `yes`:

   ```bash
   IGNORE_UPDATES="yes"
   ```

## Step 8: Compile the Linux kernel

Start the build process:

```bash
sudo ./build.sh
```

Select the appropriate options for your board and kernel version when prompted.

![image](https://github.com/user-attachments/assets/fb142587-3888-4964-bdd3-e5a3b051e725)

![image](https://github.com/user-attachments/assets/c7730fc3-59ce-404b-ad18-e95c2e2812e7)

![image](https://github.com/user-attachments/assets/87a5024e-0561-41df-9f16-231dda9f56db)

![image](https://github.com/user-attachments/assets/f078d22f-886a-40b0-9bc6-8b8773c8ac00)

After a successful build you will see messages like the ones below (note: the first build can take nearly 40 minutes):

![image](https://github.com/user-attachments/assets/addcd887-8dda-4b7c-a2fb-f4ddd6c011f5)

Check the resulting file:

![image](https://github.com/user-attachments/assets/f32ef375-33cd-4c30-8af0-e86cdefe0e13)

## Step 9: Install the New Kernel

Need to install only the **linux-image-current-rockchip-rk3588_1.0.8_arm64.deb** package:

```bash
sudo apt purge -y linux-image-current-rockchip-rk3588
sudo dpkg -i output/debs/linux-image-current-rockchip-rk3588_1.0.8_arm64.deb
```

## Step 10: Verify the Updated NPU Driver Version

Reboot the system:

```bash
sudo reboot
```

After rebooting, verify the NPU driver version:

```bash
sudo cat /sys/kernel/debug/rknpu/version
```
The output should now indicate version 0.9.8.
![image](https://github.com/user-attachments/assets/80a35e0a-8389-4800-bf2d-c27547155f0c)

## Contributing your build

Step 9 produced a `linux-image-current-rockchip-rk3588_1.0.8_arm64.deb` package for your board. Contributing it lets anyone with the same Orange Pi board update their NPU driver with the one-line installer — no compilation required.

To contribute your package:

1. Take the built `.deb` from `output/debs/` and rename it to this project's convention, `<model>-<soc>-<build>-arm64.deb` (for example, `orangepi5b-rk3588s-108-arm64.deb`).
2. Open a Pull Request that:
   - adds the `.deb` under `debs/`, and
   - flips your board's row in `manifest.tsv` from `planned` to `supported`, filling in its `deb_path` and `sha256` (run `sha256sum <file>` to get the hash). The [README](README.md) documents the manifest format.

The maintainer reviews the package, and its `sha256` in the manifest becomes the integrity anchor the installer verifies before it touches the kernel — so only the exact build that was reviewed is ever installed.
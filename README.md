# nvuv

CLI tool for undervolting (_indirect_) and overclocking NVIDIA gpu on Linux

## Install

- GH [releases](https://github.com/doums/nvuv/releases/latest)
- AUR https://aur.archlinux.org/packages/nvuv

## Quick start

> [!TIP]
> `nvuv -h`

First check your GPU specs

```sh
> nvuv get
power limit: 250W (default: 250W, range: 175..250W)
gpu clock range: 200..3000MHz
memory clock range: 400..15000MHz
gpu clock offset: 0MHz (-1000..1000)
memory clock offset: 0MHz (-2000..6000)

# by P-states
> nvuv ps

# query a given P-states
> nvuv get 0
> nvuv ps 0

# print general gpu(s) info
> nvuv gpu
```

> [!TIP]
> Use `-i GPU_INDEX` to select a specific GPU if you have multiple

Then tune - **root required**

```sh
# Set power limit to 175 W
> sudo nvuv set -w 175

# Lock gpu clock between 200..2400 MHz
> sudo nvuv set -g 200..2400
# If needed lock memory clock with `-m`

# Set gpu/memory clock offset to +200/+500 MHz (support negative)
> sudo nvuv set -G 200 -M 500
```

To reset to default - **root required**

```sh
> sudo nvuv reset -A
```

> [!IMPORTANT]
> Settings changes do not survive reboot/resume or driver reload.\
> For this, a systemd service is provided to apply a config
> automatically (see below).

`nvuv` can apply settings from a config file, default is `/etc/nvuv/nvuv.toml`.\
Edit the file to set desired settings:

```toml
# Comment any property to keep the default

[[gpu]]
power_limit = 175 # W
gpu_offset = 200 # MHz
mem_offset = 500

[gpu.gpu_clocks.locked]
# Comment min value to use the lowest default freq
min = 200 # MHz
max = 2400

# To lock memory clock uncomment
# [gpu.mem_clocks.locked]
# min = 123
# max = 1234

# Reset clocks to default value
# Useful for switching between different configs for different use cases
# [gpu.gpu_clocks]
# reset = 1
# [gpu.mem_clocks]
# reset = 1

# If multi GPUs add more section as needed
# [[gpu]]
# …
```

> [!TIP]
> Run `nvuv cfg` to check the config is valid
> Use `--config /path/to/config.toml` to specify a custom config file

To apply the config immediately - **root required**

```sh
> sudo nvuv applycfg
```

### Run as a systemd service

To apply the config at startup and after resume/driver reload,
enable the provided systemd [service](.pkg/nvuv.service):

```sh
sudo systemctl enable --now nvuv.service
```

If needed, to use a custom file, [override](https://wiki.archlinux.org/title/Systemd#Editing_provided_units)
the service

```sh
ExecStart=/usr/bin/nvuv applycfg --config /path/to/config.toml
```

## Implementation details

`nvuv` is a thin wrapper around NVIDIA's [NVML library](https://docs.nvidia.com/deploy/nvml-api/)

---

### NVIDIA undervolt on Linux?

NVIDIA does not expose direct voltage control on Linux (unlike on
Windows and popular tools like MSI Afterburner).\
Voltage-freq curve is locked at driver level.\
We have to trick and use a technique: _indirect undervolting_

1. Lock the GPU's maximum clock speed (underclocking)
2. Apply a positive clock offset (overclocking) to the locked range

Result: the GPU runs at (roughly) the same performance with lower
voltage and power draw, reducing temp and fan noise

## License

Apache License 2.0 WITH Commons-Clause-1.0

---

_trad' coded_

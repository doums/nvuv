# nvuv

CLI tool for undervolting NVIDIA gpu on Linux

## Install

_will be available soon at_

- GH [releases](https://github.com/doums/nvuv/releases/latest)
- AUR https://aur.archlinux.org/packages/nvuv

_WIP_

## Quick start

> [!TIP]
> `nvuv -h`

First check your GPU's supported power limits, clock and offset ranges

```sh
> nvuv get w
power limit: 250W (default: 250W, range: 175..250W)

> nvuv get gc
gpu clock range: 200..3000MHz

> nvuv get mc
memory clock range: 400..15000MHz

> nvuv get go
gpu clock offset: 0MHz (-1000..1000)

> nvuv get mo
memory clock offset: 0MHz (-2000..6000)

# or in one command listing all P-states
> nvuv get psc
```

> [!TIP]
> Use `-g GPU_INDEX` to set a specific GPU if you have multiple

Then tune - **root required**

```sh
# Set power limit to 175 W
> sudo nvuv set w 175

# Lock gpu clock between 200..2400 MHz
> sudo nvuv set gl 2400 200
# If needed lock memory clock with `ml`

# Set gpu clock offset to +200 MHz (support negative)
> sudo nvuv set go 200

# Set memory clock offset to +500 MHz
> sudo nvuv set mo 500
```

> [!IMPORTANT]
> Settings changes do not survive reboot/resume or driver reload.\
> For this, a systemd service is provided to apply a config
> automatically (see below).

`nvuv` can apply settings from a config file, default is `/etc/nvuv/nvuv.toml`.\
Edit the file to set desired settings:

```toml
# comment any property to keep the default

[[gpu]]
power_limit = 175 # W
gpu_offset = 200 # MHz
mem_offset = 500

[gpu.gpu_locked_clocks]
# comment min value to use the lowest default freq
min = 200 # MHz
max = 2400

# if you want to lock memory clock uncomment
# [gpu.mem_locked_clocks]
# min = 123
# max = 1234

# if multi GPUs add more section as needed
# [[gpu]]
# …
```

> [!TIP]
> Use `--config /path/to/config.toml` to specify a custom config file

Check the config is valid:

```sh
nvuv cfg
```

To apply the config immediately - **root required**

```sh
sudo nvuv applycfg
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
ExecStart=/usr/bin/nvuv --config /path/to/config.toml
```

## Implementation details

`nvuv` is a thin wrapper around NVIDIA's [NVML library](https://docs.nvidia.com/deploy/nvml-api/)

_trad' coded with my human hands_

---

### NVIDIA undervolt on Linux?

NVIDIA does not expose direct voltage control on Linux (unlike on
Windows and popular tools like MSI Afterburner).\
Voltage-freq curve is locked at driver level.\
We have to trick and use a technique: _indirect undervolting_

1. Lock the GPU's maximum clock speed
2. Apply a positive clock offset (overclocking) to the locked range

Result: the GPU runs at (roughly) the same performance with lower
voltage and power draw, reducing temp and fan noise


## License

Apache License 2.0


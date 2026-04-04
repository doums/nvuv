#!/bin/bash

# NOTE: nvml.h get from https://github.com/NVIDIA/nvidia-settings/blob/main/src/nvml.h
# No official source apart from
# https://anaconda.org/channels/nvidia/packages/cuda-nvml-dev/files
# which provides .conda packages, so not useful.

# TODO: this is **YOLO** considering the risk of incompatibility
# between the header and the actual lib version present in the system
# Eg. for Arch probably better to switch to the one living in Arch
# `cuda` package

curl -LSsf -o include/nvml.h https://raw.githubusercontent.com/NVIDIA/nvidia-settings/refs/heads/main/src/nvml.h

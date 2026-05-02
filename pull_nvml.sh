#!/bin/bash

# Get nvml.h from https://developer.download.nvidia.com/compute/cuda/redist/cuda_nvml_dev/linux-x86_64/

# TODO: kinda **YOLO** considering the risk of incompatibility
# between the header and the actual lib version present in the system
# Ideally we should use the same version of the header as the one present in the system
# eg. on Arch it is provided by the nvidia-utils package
# In the future consider static linking to eliminate compat issue

version=13.2.82
archive="cuda_nvml_dev-linux-x86_64-$version-archive"
archive_xz="$archive.tar.xz"
url="https://developer.download.nvidia.com/compute/cuda/redist/cuda_nvml_dev/linux-x86_64/$archive_xz"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -LSsf -o "$tmp/$archive_xz" "$url"
tar -xf "$tmp/$archive_xz" -C "$tmp"
mv "$tmp/$archive/include/nvml.h" ./include/

echo 'DONE'

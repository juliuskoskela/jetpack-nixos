# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the "uefi" DTB overlay that makes UEFI reserve the VM carve-outs.
#
# The kernel only learns about the carve-outs from /reserved-memory, which
# UEFI ignores, so they appear as EfiConventionalMemory and the EFI stub may
# put a randomized kernel image inside one. The overlay adds
# /firmware/uefi/reserved-ranges, which the edk2-nvidia patch
# pkgs/uefi-firmware/reserve-dtb-ranges.diff turns into memory allocation HOBs.
{ lib }:
{ pkgs
, support
, includeDispVmRam
  # "boot-services-data" keeps Linux's view unchanged. "reserved" makes the
  # ranges EfiReservedMemoryType, which Linux treats as no-map.
, memoryType ? "boot-services-data"
,
}:
let
  allRanges = lib.attrValues support.passthrough.reservedMemory;
  ranges = lib.filter (range: includeDispVmRam || !(range.dispVmRam or false)) allRanges;
  node = range: lib.removeSuffix "_p" range.symbol;
  cell = value: "0x${lib.toLower (lib.toHexString value)}";
  hi = value: cell (value / 4294967296);
  lo = value: cell (lib.mod value 4294967296);
  reg = lib.concatMapStringsSep " " (range: "${hi range.base} ${lo range.base} ${hi range.size} ${lo range.size}") ranges;
  source = pkgs.writeText "uefi-reserved-ranges.dts" ''
    /dts-v1/;
    /plugin/;

    / {
      overlay-name = "UEFI reserved ranges";

      fragment@0 {
        target-path = "/";
        board_config {
          sw-modules = "uefi";
        };

        __overlay__ {
          firmware {
            uefi {
              reserved-ranges {
                compatible = "ghaf,uefi-reserved-ranges";
                #address-cells = <2>;
                #size-cells = <2>;
                reg = <${reg}>;
                ${lib.optionalString (memoryType == "reserved") "ghaf,reserved-memory-type-reserved;"}
              };
            };
          };
        };
      };
    };
  '';
  # "<node> <base> <size> <dispVmRam>" for every carve-out, as the manifest
  # sees them and as gpu_passthrough_overlay.dts declares them.
  describe = range: "${node range} ${toString range.base} ${toString range.size} ${if range.dispVmRam or false then "1" else "0"}";
  expected = pkgs.writeText "carveouts-manifest.txt" (lib.concatMapStringsSep "\n" describe allRanges + "\n");
in
pkgs.buildPackages.runCommand "UefiReservedRanges.dtbo"
{
  nativeBuildInputs = [ pkgs.buildPackages.dtc pkgs.buildPackages.gawk ];
} ''
  gawk '
    /^#ifdef GHAF_INCLUDE_DISPVM_RAM/ { disp = 1 }
    /^#endif/ { disp = 0 }
    /^[ \t]*[A-Za-z0-9_]+:[ \t]*[A-Za-z0-9_]+@[0-9a-fx]+[ \t]*\{/ {
      name = $2; sub(/@.*/, "", name); dma = 0
    }
    /compatible = "removed-dma-pool"/ { dma = 1 }
    dma && /reg = </ {
      gsub(/[<>;]/, " "); n = split($0, f, /[ \t]+/)
      for (i = 1; i <= n; i++) if (f[i] == "=") break
      base = strtonum(f[i + 1]) * 4294967296 + strtonum(f[i + 2])
      size = strtonum(f[i + 3]) * 4294967296 + strtonum(f[i + 4])
      printf "%s %.0f %.0f %d\n", name, base, size, disp
      dma = 0
    }
  ' ${support}/device-trees/gpu-vm/gpu_passthrough_overlay.dts | sort > kernel.txt
  sort ${expected} > manifest.txt
  if ! diff -u manifest.txt kernel.txt; then
    echo "manifest.nix reservedMemory and gpu_passthrough_overlay.dts disagree" >&2
    exit 1
  fi

  dtc -@ -W no-unit_address_vs_reg -W no-reg_format -W no-avoid_default_addr_size -I dts -O dtb ${source} -o $out
''

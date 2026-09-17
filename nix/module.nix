{ source }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.modern-fs-benchmark;

  benchmark = import ./benchmark-package.nix {
    inherit pkgs source;
    zfsPackage = cfg.zfsPackage;
  };
  benchmarkPackages = benchmark.runtimeInputs;

  runBenchmark = pkgs.writeShellApplication {
    name = "modern-fs-benchmark-run";
    runtimeInputs = benchmarkPackages;
    text = ''
      export MANAGED_BENCHMARK_PROFILE=${lib.escapeShellArg cfg.hardwareProfile}
      export MANAGED_BENCHMARK_DEVICES=${lib.escapeShellArg (lib.concatStringsSep " " cfg.devices)}
      export MANAGED_BENCHMARK_SPARE_DEVICE=${lib.escapeShellArg cfg.spareDevice}
      export MANAGED_BENCHMARK_ZFS_SINGLE_DEVICE=${lib.escapeShellArg cfg.zfsSingleDevice}
      export MANAGED_BENCHMARK_COMMAND=${lib.escapeShellArg "${benchmark.package}/bin/modern-fs-benchmark"}
      exec ${pkgs.bash}/bin/bash ${source}/scripts/managed-hardware-runner.sh "$@"
    '';
  };
  sudoShim = pkgs.writeShellScriptBin "sudo" ''
    exec /run/wrappers/bin/sudo "$@"
  '';
in
{
  options.services.modern-fs-benchmark = {
    enable = lib.mkEnableOption "the modern filesystem benchmark runner";

    repository = lib.mkOption {
      type = lib.types.str;
      description = "GitHub repository whose Actions jobs this runner accepts.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a GitHub runner PAT or registration token.";
    };

    runnerName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Name shown for the self-hosted GitHub runner.";
    };

    hardwareProfile = lib.mkOption {
      type = lib.types.str;
      default = "farm3";
      description = "Stable hardware profile recorded in every benchmark result.";
    };

    runnerLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "fs-benchmark" ];
      description = "Labels used to route benchmark jobs to this runner.";
    };

    runnerGroup = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional GitHub organization runner group restricted to trusted repositories.";
    };

    ephemeral = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Re-register a clean runner after every job; requires a PAT in tokenFile.";
    };

    devices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Four disposable block devices used as array members.";
    };

    spareDevice = lib.mkOption {
      type = lib.types.str;
      description = "Disposable block device used as the rebuild target.";
    };

    zfsSingleDevice = lib.mkOption {
      type = lib.types.str;
      description = "Dedicated 32 GiB block device used by zfs/single.";
    };

    enableBcachefs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Build and load bcachefs for the cluster-selected kernel.";
    };

    enableZfs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable ZFS support for the cluster-selected kernel.";
    };

    zfsPackage = lib.mkOption {
      type = lib.types.package;
      default = config.boot.zfs.package;
      defaultText = lib.literalExpression "config.boot.zfs.package";
      description = "Cluster-selected ZFS package exposed to benchmark jobs.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length cfg.devices == 4;
        message = "services.modern-fs-benchmark.devices must contain exactly four devices";
      }
      {
        assertion = cfg.spareDevice != "";
        message = "services.modern-fs-benchmark.spareDevice must not be empty";
      }
      {
        assertion = builtins.length (lib.unique (cfg.devices ++ [ cfg.spareDevice cfg.zfsSingleDevice ])) == 6;
        message = "services.modern-fs-benchmark devices, spareDevice, and zfsSingleDevice must be distinct";
      }
    ];

    boot.extraModulePackages =
      lib.optional cfg.enableBcachefs config.boot.kernelPackages.bcachefs
      ++ lib.optional cfg.enableZfs config.boot.zfs.modulePackage;
    boot.kernelModules =
      [ "dm_raid" "dm_snapshot" "dm_integrity" ]
      ++ lib.optional cfg.enableBcachefs "bcachefs"
      ++ lib.optional cfg.enableZfs "zfs";
    services.udev.packages = lib.optional cfg.enableZfs cfg.zfsPackage;
    users.groups.modern-fs-benchmark = { };
    users.users.modern-fs-benchmark = {
      isSystemUser = true;
      group = "modern-fs-benchmark";
    };

    security.sudo.extraRules = [
      {
        users = [ "modern-fs-benchmark" ];
        commands = [
          {
            command = "${runBenchmark}/bin/modern-fs-benchmark-run";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    services.github-runners.modern-fs-benchmark = {
      enable = true;
      url = cfg.repository;
      tokenFile = cfg.tokenFile;
      name = cfg.runnerName;
      replace = true;
      extraLabels = cfg.runnerLabels;
      runnerGroup = cfg.runnerGroup;
      ephemeral = cfg.ephemeral;
      user = "modern-fs-benchmark";
      group = "modern-fs-benchmark";
      extraPackages = benchmarkPackages ++ [ runBenchmark sudoShim ];
      serviceOverrides = {
        AmbientCapabilities = lib.mkForce null;
        CapabilityBoundingSet = lib.mkForce [ "~" ];
        DeviceAllow = lib.mkForce null;
        NoNewPrivileges = lib.mkForce false;
        PrivateDevices = lib.mkForce false;
        PrivateMounts = lib.mkForce false;
        PrivateTmp = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
        ProtectClock = lib.mkForce false;
        ProtectControlGroups = lib.mkForce false;
        ProtectHome = lib.mkForce false;
        ProtectHostname = lib.mkForce false;
        ProtectKernelLogs = lib.mkForce false;
        ProtectKernelModules = lib.mkForce false;
        ProtectKernelTunables = lib.mkForce false;
        ProtectProc = lib.mkForce "default";
        ProtectSystem = lib.mkForce false;
        RemoveIPC = lib.mkForce false;
        RestrictAddressFamilies = lib.mkForce null;
        RestrictNamespaces = lib.mkForce false;
        RestrictSUIDSGID = lib.mkForce false;
        SystemCallFilter = lib.mkForce null;
        UMask = lib.mkForce "0022";
      };
    };
  };
}

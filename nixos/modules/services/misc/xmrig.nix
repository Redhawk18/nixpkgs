{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.xmrig;
  json = pkgs.formats.json { };
  configFile = json.generate "config.json" cfg.settings;

  stateDir = "/var/lib/xmrig";
  # XMRig auto-configures the CPU/OpenCL/CUDA mining threads on first start and,
  # with `autosave`, writes the result back into its config file. That is only
  # possible if the config file is writable, so the declarative config is copied
  # into the state directory instead of being passed from the store directly.
  mutableConfigFile = "${stateDir}/config.json";
  # Records which store path the mutable config was seeded from, so the copy is
  # only refreshed when the declarative settings actually changed. Otherwise the
  # autosaved thread configuration would be discarded on every start.
  stampFile = "${stateDir}/.nix-config";

  syncConfig = pkgs.writeShellScript "xmrig-sync-config" ''
    set -eu

    if [ "$(cat ${stampFile} 2>/dev/null)" != "${configFile}" ]; then
      install -m 0600 ${configFile} ${mutableConfigFile}
      printf '%s\n' "${configFile}" > ${stampFile}
    fi
  '';
in
{
  options = {
    services.xmrig = {
      enable = lib.mkEnableOption "XMRig Mining Software";

      package = lib.mkPackageOption pkgs "xmrig" {
        example = "xmrig-mo";
      };

      settings = lib.mkOption {
        default = { };
        type = json.type;
        example = lib.literalExpression ''
          {
            autosave = true;
            cpu = true;
            opencl = false;
            cuda = false;
            pools = [
              {
                url = "pool.supportxmr.com:443";
                user = "your-wallet";
                keepalive = true;
                tls = true;
              }
            ]
          }
        '';
        description = ''
          XMRig configuration. Refer to
          <https://xmrig.com/docs/miner/config>
          for details on supported values.

          These settings are copied to `${mutableConfigFile}` on start, which is
          where XMRig persists its auto-configured mining threads when
          `autosave` is enabled. The copy is only refreshed when these settings
          change, so XMRig does not have to redo its auto-configuration on every
          restart.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.cpu.x86.msr.enable = true;

    systemd.services.xmrig = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      description = "XMRig Mining Software Service";
      serviceConfig = {
        ExecStartPre = [
          # Validate the declarative config before it replaces the mutable one.
          # `--dry-run` exits before XMRig would save anything.
          "${lib.getExe cfg.package} --config=${configFile} --dry-run"
          "${syncConfig}"
        ];
        ExecStart = "${lib.getExe cfg.package} --config=${mutableConfigFile}";
        StateDirectory = "xmrig";
        StateDirectoryMode = "0700";
        # https://xmrig.com/docs/miner/randomx-optimization-guide/msr
        # If you use recent XMRig with root privileges (Linux) or admin
        # privileges (Windows) the miner configure all MSR registers
        # automatically.
        DynamicUser = lib.mkDefault false;
      };
    };
  };

  meta = {
    maintainers = with lib.maintainers; [ ratsclub ];
  };
}

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.null-kvn-client;
  service = config.services.null-kvn-client;
  isNormalizedAbsolutePath =
    value:
    let
      components = lib.splitString "/" value;
    in
    builtins.isString value
    && lib.hasPrefix "/" value
    && value != "/"
    && lib.all (component: component != "" && component != "." && component != "..") (
      lib.tail components
    );
  clientConfig =
    if service.enable then builtins.fromTOML (builtins.readFile service.configFile) else { };
  clientStateDirectory = clientConfig.state_directory or null;
  clientStateDirectoryIsValid =
    clientStateDirectory != null
    && isNormalizedAbsolutePath clientStateDirectory
    && lib.hasPrefix "/var/lib/" clientStateDirectory;
  clientStateDirectories =
    if clientStateDirectoryIsValid then
      let
        components = lib.splitString "/" (lib.removePrefix "/var/lib/" clientStateDirectory);
      in
      lib.genList (index: lib.concatStringsSep "/" (lib.take (index + 1) components)) (
        builtins.length components
      )
    else
      [ ];
  forwardingTransitionState = "/run/null-kvn/forwarding-transition.v1";
  restoreForwarding = pkgs.writeShellScript "null-kvn-client-restore-forwarding" ''
    set -u

    state=${lib.escapeShellArg forwardingTransitionState}
    if [[ ! -f "$state" ]]; then
      exit 0
    fi
    receipts=/run/null-kvn/protection-owners.v1
    if [[ ! -d "$receipts" ]]; then
      echo "refusing to restore forwarding without protection receipts" >&2
      exit 1
    fi
    shopt -s nullglob
    entries=("$receipts"/*)
    hosts=("$receipts"/host.*)
    gateways=("$receipts"/gateway.*)
    if (( ''${#entries[@]} != 1 || ''${#hosts[@]} != 1 || ''${#gateways[@]} != 0 )) \
      || [[ ! -f "''${hosts[0]}" || -L "''${hosts[0]}" ]]; then
      echo "refusing to restore forwarding before exact host-only protection is confirmed" >&2
      exit 1
    fi
    ipv4=
    ipv6=
    trailing=
    if ! IFS=' ' read -r ipv4 ipv6 trailing <"$state"; then
      echo "failed to read saved forwarding state" >&2
      exit 1
    fi
    case "$ipv4:$ipv6:$trailing" in
      0:0:|0:1:|1:0:|1:1:) ;;
      *)
        echo "saved forwarding state is invalid" >&2
        exit 1
        ;;
    esac

    status=0
    ${pkgs.procps}/bin/sysctl -q -w "net.ipv4.ip_forward=$ipv4" || status=1
    ${pkgs.procps}/bin/sysctl -q -w "net.ipv6.conf.all.forwarding=$ipv6" || status=1
    if [[ "$status" -eq 0 ]]; then
      rm -f -- "$state"
    fi
    exit "$status"
  '';
  reconcileHostOnlyDowngrade = pkgs.writeShellScript "null-kvn-client-reconcile-host-only" ''
    set -eu

    if [[ "$#" -ne 1 ]]; then
      echo "usage: $0 CLIENT_CONFIG" >&2
      exit 2
    fi
    client_config="$1"
    state=${lib.escapeShellArg forwardingTransitionState}
    receipts=/run/null-kvn/protection-owners.v1

    if [[ ! -f "$state" ]]; then
      if [[ ! -d "$receipts" ]]; then
        exit 0
      fi
      shopt -s nullglob
      gateways=("$receipts"/gateway.*)
      if (( ''${#gateways[@]} == 0 )); then
        exit 0
      fi

      ipv4="$(${pkgs.procps}/bin/sysctl -n net.ipv4.ip_forward)"
      ipv6="$(${pkgs.procps}/bin/sysctl -n net.ipv6.conf.all.forwarding)"
      case "$ipv4:$ipv6" in
        0:0|0:1|1:0|1:1) ;;
        *)
          echo "kernel forwarding state is not binary" >&2
          exit 1
          ;;
      esac

      temporary="$state.new"
      rm -f -- "$temporary"
      umask 0077
      printf '%s %s\n' "$ipv4" "$ipv6" >"$temporary"
      chmod 0600 "$temporary"
      mv -fT -- "$temporary" "$state"
    fi

    ${pkgs.procps}/bin/sysctl -q -w net.ipv4.ip_forward=0
    ${pkgs.procps}/bin/sysctl -q -w net.ipv6.conf.all.forwarding=0
    ${cfg.package}/bin/null-kvn-client protection install --config "$client_config"
  '';
in
{
  options.programs.null-kvn-client = {
    enable = lib.mkEnableOption "the NULL KVN client package";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "Package to install for the NULL KVN client.";
    };
  };

  options.services.null-kvn-client = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the declarative NULL KVN client daemon and protection guard.";
    };

    alwaysOn = lib.mkEnableOption ''
      declarative reconnection whenever the selected managed network is ready;
      this policy intentionally overrides a manual client down action
    '';

    configFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Evaluation-time-readable public client TOML. Its state_directory must
        be normalized and strictly below /var/lib. Secrets and enrollment
        state are not part of this public module.
      '';
    };

    productConfigFile = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.package}/share/null-kvn/product-config.toml";
      defaultText = lib.literalExpression ''
        "${config.programs.null-kvn-client.package}/share/null-kvn/product-config.toml"
      '';
      description = ''
        Immutable client product TOML containing the release authority,
        candidate identity, platform, and performance tier. The default is the
        product configuration shipped by the pinned client package.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !service.alwaysOn || service.enable;
          message = "services.null-kvn-client.alwaysOn requires services.null-kvn-client.enable.";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];
    })
    (lib.mkIf service.enable {
      assertions = [
        {
          assertion = cfg.enable;
          message = "services.null-kvn-client.enable requires programs.null-kvn-client.enable.";
        }
        {
          assertion = pkgs.stdenv.hostPlatform.isLinux;
          message = "services.null-kvn-client currently supports NixOS/Linux only.";
        }
        {
          assertion = clientStateDirectoryIsValid;
          message = "services.null-kvn-client.configFile must declare one normalized state_directory below /var/lib.";
        }
      ];

      services.dbus.packages = [ cfg.package ];
      security.polkit.enable = true;
      boot.kernelModules = [ "tun" ];

      warnings = lib.optional (!config.services.resolved.enable) ''
        NULL KVN will leave /etc/resolv.conf and host DNS operator-managed.
        Direct protection can start in this mode with a runtime warning;
        Strict protection requires a working systemd-resolved stub.
      '';

      systemd.services.null-kvn-client-guard = {
        description = "NULL KVN persistent client protection";
        path = [
          pkgs.coreutils
          pkgs.nftables
        ];
        requiredBy = [ "network-pre.target" ];
        before = [
          "network-pre.target"
          "null-kvn-client.service"
        ];
        after = [
          "local-fs.target"
          "nftables.service"
        ];
        unitConfig.DefaultDependencies = false;
        restartTriggers = [
          service.configFile
          service.productConfigFile
        ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = "client.toml:${service.configFile}";
          ExecStart = "${cfg.package}/bin/null-kvn-client protection install --config %d/client.toml";
          ExecStop = "${cfg.package}/bin/null-kvn-client protection purge";
          User = "root";
          Group = "root";
          RuntimeDirectory = "null-kvn";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = "yes";
          StateDirectory = clientStateDirectories;
          StateDirectoryMode = "0700";
          UMask = "0077";
          TimeoutStartSec = "6s";
          TimeoutStopSec = "6s";
        };
      };

      systemd.services.null-kvn-client = {
        description = "NULL KVN client daemon";
        path = [
          pkgs.coreutils
          pkgs.nftables
        ];
        wantedBy = [ "multi-user.target" ];
        requires = [ "null-kvn-client-guard.service" ];
        wants = [
          "network-pre.target"
        ]
        ++ lib.optionals service.alwaysOn [ "null-kvn-client-always-on.service" ]
        ++ lib.optionals config.services.resolved.enable [ "systemd-resolved.service" ];
        after = [
          "dbus.socket"
          "network-pre.target"
          "null-kvn-client-guard.service"
        ]
        ++ lib.optionals config.services.resolved.enable [ "systemd-resolved.service" ];
        restartTriggers = [
          service.configFile
          service.productConfigFile
        ];
        serviceConfig = {
          Type = "dbus";
          BusName = "dev.nullkvn.Client1";
          LoadCredential = [
            "client.toml:${service.configFile}"
            "product.toml:${service.productConfigFile}"
          ];
          ExecStartPre = [
            "${reconcileHostOnlyDowngrade} %d/client.toml"
            "${cfg.package}/bin/null-kvn-client protection recover-routing"
            restoreForwarding
          ];
          ExecStart = lib.escapeShellArgs (
            [
              "${cfg.package}/bin/null-kvn-client"
              "daemon"
              "--config"
              "%d/client.toml"
              "--product-config"
              "%d/product.toml"
            ]
            ++ lib.optional service.alwaysOn "--always-on"
          );
          User = "root";
          Group = "root";
          RuntimeDirectory = "null-kvn";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = "yes";
          StateDirectory = clientStateDirectories;
          StateDirectoryMode = "0700";
          UMask = "0077";
          Restart = "on-failure";
          RestartSec = "1s";
          TimeoutStopSec = "6s";
        };
      };

      systemd.services.null-kvn-client-always-on = lib.mkIf service.alwaysOn {
        description = "Keep the selected NULL KVN network connected";
        unitConfig.StartLimitIntervalSec = "0";
        requires = [ "null-kvn-client.service" ];
        after = [ "null-kvn-client.service" ];
        partOf = [ "null-kvn-client.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${cfg.package}/bin/null-kvn-client ensure-up --wait-ms 0";
          User = "root";
          Group = "root";
          UMask = "0077";
          Restart = "on-failure";
          RestartSec = "5s";
          TimeoutStartSec = "5s";
        };
      };

      systemd.paths.null-kvn-client-always-on = lib.mkIf service.alwaysOn {
        description = "Watch the NULL KVN managed catalog for always-on reconciliation";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = "${clientStateDirectory}/catalog.v1";
          Unit = "null-kvn-client-always-on.service";
        };
      };
    })
  ];
}

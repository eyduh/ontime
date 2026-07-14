{ config, lib, pkgs, ... }:

let
  cfg = config.services.ontime;
in
{
  options.services.ontime = {
    enable = lib.mkEnableOption "Ontime server";

    package = lib.mkOption {
      type = lib.types.package;
      # Self-contained default so the module works both as a flake output and
      # when imported directly (nix-build / configuration.nix imports).
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The Ontime package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4001;
      description = "TCP port for the HTTP / WebSocket / MCP server.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ontime";
      description = "Writable directory for the database, projects and uploads (ONTIME_DATA).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the HTTP port in the firewall.";
    };

    openOscFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the OSC UDP ports (8888, 9999) in the firewall.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { TZ = "Europe/Oslo"; };
      description = "Extra environment variables for the service.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.ontime = {
      description = "Ontime server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        NODE_ENV = "production";
        PORT = toString cfg.port;
        ONTIME_DATA = cfg.dataDir;
      } // cfg.environment;

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = 5;

        DynamicUser = true;
        StateDirectory = lib.mkIf (cfg.dataDir == "/var/lib/ontime") "ontime";
        # If dataDir is customised, ensure it exists and is owned by the service.
        ReadWritePaths = lib.mkIf (cfg.dataDir != "/var/lib/ontime") [ cfg.dataDir ];

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # node JIT needs W^X off
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openOscFirewall [ 8888 9999 ];
  };
}

# Multi-instance Ontime NixOS module.
#
# Each named instance ("stage") is an independent Ontime server with its own
# port, data directory and systemd unit (ontime-<name>.service). Run several
# behind one reverse proxy to mirror the Cloud multi-stage setup.
#
#   services.ontime = {
#     enable = true;
#     instances = {
#       stage-a.port = 4001;
#       stage-b.port = 4002;
#       stage-c = { port = 4003; firewallInterfaces = [ "tailscale0" ]; };
#     };
#   };
#
# Access control is still Ontime's single shared password per instance: set
# SESSION_PASSWORD in an instance's `environment`. Multi-user / OIDC access is
# expected to live in a reverse-proxy forward-auth layer in front, not here.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.ontime;
  oscPorts = [ 8888 9999 ];

  # ── Submodule for one instance ("stage") ───────────────────────────────────
  instanceModule = { name, ... }: {
    options = {
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Override the Ontime package for this instance. null → services.ontime.package.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = ''
          TCP port for this instance's HTTP / WebSocket / MCP server.
          Must be unique across instances.
        '';
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/ontime-${name}";
        description = "Writable directory for the database, projects and uploads (ONTIME_DATA).";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Open this instance's HTTP port on all interfaces. For finer control
          (e.g. only a LAN interface, letting a reverse proxy handle the public
          side), leave this off and use `firewallInterfaces` instead.
        '';
      };

      firewallInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "eth0" "tailscale0" ];
        description = ''
          Interfaces on which to open this instance's HTTP port. Loopback
          traffic is never filtered, so a reverse proxy on the same host reaches
          the server without opening any firewall port.
        '';
      };

      openOscFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Open the OSC UDP ports (8888, 9999) on all interfaces.";
      };

      oscFirewallInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "eth0" ];
        description = "Interfaces on which to open the OSC UDP ports (8888, 9999).";
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { TZ = "Europe/Oslo"; SESSION_PASSWORD = "changeme"; };
        description = ''
          Extra environment variables for this instance. SESSION_PASSWORD sets
          the shared-password access gate. Note values here land in the systemd
          unit (world-readable in the store), so prefer a secrets mechanism for
          real deployments.
        '';
      };
    };
  };

  # ── Per-instance config builder ────────────────────────────────────────────
  # StateDirectory=ontime-<name> when dataDir is left at the managed default;
  # otherwise the operator owns the path and we just grant write access to it.
  mkUnit = name: inst:
    let
      svcName = "ontime-${name}";
      usesStateDir = inst.dataDir == "/var/lib/${svcName}";
    in
    {
      description = "Ontime server (${name})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        NODE_ENV = "production";
        PORT = toString inst.port;
        ONTIME_DATA = inst.dataDir;
      } // inst.environment;

      serviceConfig = {
        ExecStart = lib.getExe (if inst.package != null then inst.package else cfg.package);
        Restart = "on-failure";
        RestartSec = 5;

        DynamicUser = true;
        StateDirectory = lib.mkIf usesStateDir svcName;
        ReadWritePaths = lib.mkIf (!usesStateDir) [ inst.dataDir ];

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        # Ontime calls os.networkInterfaces() at startup (getifaddrs), which
        # opens an AF_NETLINK socket; the node/glibc resolver also needs
        # AF_UNIX. Without these the socket() call is denied with EAFNOSUPPORT
        # (libuv error 97) and the server aborts before it can listen.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # node JIT needs W^X off
      };
    };

  mkFirewall = inst: {
    allowedTCPPorts = lib.mkIf inst.openFirewall [ inst.port ];
    allowedUDPPorts = lib.mkIf inst.openOscFirewall oscPorts;
    interfaces = lib.mkMerge [
      (lib.genAttrs inst.firewallInterfaces (_: { allowedTCPPorts = [ inst.port ]; }))
      (lib.genAttrs inst.oscFirewallInterfaces (_: { allowedUDPPorts = oscPorts; }))
    ];
  };

  allPorts = lib.mapAttrsToList (_: i: i.port) cfg.instances;
in
{
  options.services.ontime = {
    enable = lib.mkEnableOption "Ontime server(s)";

    package = lib.mkOption {
      type = lib.types.package;
      # Self-contained default so the module works both as a flake output and
      # when imported directly (nix-build / configuration.nix imports).
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "Default Ontime package for all instances (overridable per instance).";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule instanceModule);
      default = { };
      example = lib.literalExpression ''
        {
          stage-a.port = 4001;
          stage-b.port = 4002;
          stage-c = { port = 4003; firewallInterfaces = [ "tailscale0" ]; };
        }
      '';
      description = ''
        Independent Ontime instances ("stages"), each with its own port, data
        directory and systemd unit (ontime-<name>.service). Run several behind a
        reverse proxy to mirror the Cloud multi-stage setup.
      '';
    };
  };

  # Keep the top-level keys here static (assertions / systemd.services /
  # networking.firewall). The per-instance expansion lives in the *values* via
  # mapAttrs'/mkMerge; putting it at the config root instead makes the set of
  # keys this module defines depend on cfg.instances, which the module system
  # cannot resolve without evaluating the config → infinite recursion.
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.length allPorts == lib.length (lib.unique allPorts);
      message = "services.ontime: instances must use distinct ports; got ${toString allPorts}.";
    }];

    systemd.services = lib.mapAttrs'
      (name: inst: lib.nameValuePair "ontime-${name}" (mkUnit name inst))
      cfg.instances;

    networking.firewall = lib.mkMerge (lib.mapAttrsToList (_: mkFirewall) cfg.instances);
  };
}

# Legacy (non-flake) entry point.
#
#   nix-build            # builds the ontime package
#   nix-build -A ontime  # same, explicit
#
# The NixOS module lives at ./nix/module.nix and can be imported directly:
#   imports = [ /path/to/ontime/nix/module.nix ];
{
  pkgs ? import <nixpkgs> { },
}:
rec {
  ontime = pkgs.callPackage ./nix/package.nix { };
  default = ontime;
}

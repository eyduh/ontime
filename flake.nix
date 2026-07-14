{
  description = "Ontime - time keeping for live events (server)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        ontime = pkgs.callPackage ./nix/package.nix { };
        default = ontime;
      });

      nixosModules.default = import ./nix/module.nix;

      checks = forAllSystems (pkgs: {
        build = self.packages.${pkgs.system}.ontime;
      });
    };
}

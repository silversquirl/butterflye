{
  inputs = {
    nixpkgs.url = "nixpkgs";
    zig.url = "github:silversquirl/zig-flake";
    zig.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    nixpkgs,
    zig,
    ...
  }: let
    forAllSystems = f:
      builtins.mapAttrs
      (system: pkgs: f pkgs zig.packages.${system}.zig_0_15_1)
      nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems (pkgs: zig: {
      default = pkgs.mkShellNoCC {
        packages = [pkgs.bash zig zig.zls pkgs.kakoune pkgs.wayland-scanner];
      };
    });

    formatter = forAllSystems (pkgs: zig:
      pkgs.writeShellScriptBin "butterflye-formatter" ''
        ${pkgs.lib.getExe zig} fmt .
        ${pkgs.lib.getExe pkgs.ripgrep} -0l 'keep-sorted (start|end)' |
          while IFS= read -rd "" f; do
            ${pkgs.lib.getExe pkgs.keep-sorted} -- "$f"
          done
      '');

    packages = forAllSystems (pkgs: zig: {
      default = zig.makePackage {
        pname = "butterflye";
        version = "0.0.0";
        src = ./.;
        zigReleaseMode = "fast";
        buildInputs = [pkgs.kakoune];
        # depsHash = "<replace this with the hash Nix provides in its error message>"
      };
    });
  };
}

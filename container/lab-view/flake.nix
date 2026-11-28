# GTK4 + PyGObject for the lab view window (app.py); `nix develop path:<this dir> --command python3 app.py show`.
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ (pkgs.python3.withPackages (ps: [ ps.pygobject3 ])) pkgs.gtk4 pkgs.gobject-introspection pkgs.grim ];
      };
    };
}

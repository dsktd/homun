# sway whose nested host window has the app-id homun-lab-session (wlroots hardcodes "wlroots"
# and sway never calls wlr_wl_output_set_app_id).
let
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};
  wlroots = pkgs.wlroots_0_20.overrideAttrs (o: {
    postPatch = (o.postPatch or "") + ''
      substituteInPlace backend/wayland/output.c --replace-fail '"wlroots";' '"homun-lab-session";'
    '';
  });
in
pkgs.sway.override {
  sway-unwrapped = pkgs.sway-unwrapped.override { wlroots_0_20 = wlroots; };
}

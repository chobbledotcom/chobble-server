{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.chobble-server;
in
{
  options.services.chobble-server.redirects = {
    redirectHosts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "old.example.com" = "https://new.example.com";
        "blog.example.org" = "https://new-site.com/blog";
      };
      description = ''
        Domain redirect configuration where each key is the source domain
        and the value is the destination URL for 301 redirects.
      '';
    };
  };

  config = lib.mkIf (cfg.redirectHosts != { }) {
    services.caddy.virtualHosts = lib.mkMerge [
      (lib.mapAttrs (domain: destination: {
        listenAddresses = [ "0.0.0.0" ];
        extraConfig = ''
          redir ${destination} 301
        '';
        logFormat = "discard";
      }) cfg.redirectHosts)
    ];
  };
}

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
  options.services.chobble-server = {
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

  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts = lib.mkMerge [
      (lib.concatMapAttrs (
        domain: destination:
        let
          # Check if destination already has a path after the domain
          url = builtins.match "([^/]+//[^/]+)(/.+)?" destination;
          hasPath = url != null && builtins.elemAt url 1 != null;
          redirectTarget = if hasPath then destination else "${destination}{uri}";
        in
        {
          # HTTP version of the domain
          "http://${domain}" = {
            extraConfig = ''
              redir ${redirectTarget} 301
            '';
            logFormat = "output discard";
          };
          # HTTPS version of the domain
          "https://${domain}" = {
            extraConfig = ''
              redir ${redirectTarget} 301
            '';
            logFormat = "output discard";
          };
        }
      ) cfg.redirectHosts)
    ];
  };
}

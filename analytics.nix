{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.chobble-server;
  shortHash = str: builtins.substring 0 8 (builtins.hashString "sha256" str);
in
{
  options.services.chobble-server = {
    analyticsHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "analytics.example.com"
      ];
      description = "List of analytics domains to configure";
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts = lib.mkMerge [
      (lib.concatMapAttrs (
        _: host:
        {
          # HTTP version - redirect to HTTPS
          "http://${host}" = {
            extraConfig = ''
              redir https://${host}{uri} 301
            '';
            logFormat = "output discard";
          };
          # HTTPS version - serve the actual site
          "https://${host}" = {
            extraConfig = ''
              reverse_proxy :8081
            '';
            logFormat = "output discard";
          };
        }
      ) (lib.genAttrs cfg.analyticsHosts (host: host)))
    ];

  };
}

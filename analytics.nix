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
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            apiKey = lib.mkOption {
              type = lib.types.str;
              description = "API key for this analytics domain";
            };
            targets = lib.mkOption {
              type = lib.types.listOf lib.types.str; # Now just an array of domain strings
              description = "List of domains to track";
            };
          };
        }
      );
      default = { };
      example = {
        "analytics.example.com" = {
          apiKey = "abc123";
          targets = [
            "example.com"
            "blog.example.com"
          ];
        };
      };
      description = "Configuration for analytics domains and their targets";
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts = lib.mkMerge [
      (builtins.mapAttrs (host: _: {
        listenAddresses = [ "0.0.0.0" ];
        extraConfig = ''
          reverse_proxy :8081
        '';
        logFormat = "output discard";
      }) cfg.analyticsHosts)
    ];

    systemd.services = lib.mkMerge [
      (lib.concatMapAttrs (
        analyticsHost: hostConfig:
        lib.foldl' (
          acc: domain:
          lib.recursiveUpdate acc {
            "goatcounter-import-${shortHash domain}" = {
              description = "Goatcounter log import for ${domain}";
              after = [
                "network-online.target"
                "caddy.service"
              ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                User = "caddy";
                Group = "caddy";
                Environment = "GOATCOUNTER_API_KEY=${hostConfig.apiKey}";
                ExecStart = ''
                  ${pkgs.goatcounter}/bin/goatcounter \
                    import \
                    -follow \
                    -format=common \
                    -site="https://${analyticsHost}" \
                    -exclude 'status:404' \
                    /var/log/caddy/${domain}.log
                '';
              };
            };
          }
        ) { } hostConfig.targets
      ) cfg.analyticsHosts)
    ];
  };
}

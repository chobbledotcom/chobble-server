{ config, lib, pkgs, ... }:
let
  cfg = config.services.chobble-server;  # Changed to use chobble-server config
in {
  options.services.chobble-server = {  # Changed namespace
    analyticsHosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          apiKey = lib.mkOption {
            type = lib.types.str;
            description = "API key for this analytics domain";
          };
          targets = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                domain = lib.mkOption {
                  type = lib.types.str;
                  description = "Domain to track (e.g., example.com)";
                };
                logPath = lib.mkOption {
                  type = lib.types.str;
                  default = "/var/www/";
                  description = "Base path where logs for this domain are stored";
                };
              };
            });
            description = "List of domains to track and their log locations";
          };
        };
      });
      default = {};
      description = "Configuration for analytics domains and their targets";
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts = lib.mkMerge [
      (builtins.mapAttrs (host: _: {
        listenAddresses = ["0.0.0.0"];
        extraConfig = ''
          reverse_proxy :8081
        '';
      }) cfg.analyticsHosts)
    ];

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (analyticsHost: hostConfig:
        lib.foldl' (acc: target:
          lib.recursiveUpdate acc {
            "goatcounter-import-${lib.replaceStrings ["."] ["-"] target.domain}" = {
              description = "Goatcounter log import for ${target.domain}";
              after = [ "network-online.target" "caddy.service" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                User = "caddy";
                Group = "caddy";
                Environment = "GOATCOUNTER_API_KEY=${hostConfig.apiKey}";
                ExecStart = ''
                  ${pkgs.goatcounter}/bin/goatcounter \
                    import \
                    -follow \
                    -format=combined \
                    -site="https://${analyticsHost}" \
                    -exclude 'path:glob:/assets/*' \
                    -exclude 'status:404' \
                    -exclude redirect \
                    -exclude 'path:glob:/img/*' \
                    ${target.logPath}/access.log
                '';
              };
            };
          }
        ) {} hostConfig.targets
      ) cfg.analyticsHosts)
    ];
  };
}

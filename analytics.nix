{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.chobble-server;
  shortHash = str: builtins.substring 0 8 (builtins.hashString "sha256" str);
  loggingConfig = domain: ''
    log {
      output file /var/log/caddy/access-${domain}.log {
        roll_size 100mb
        roll_keep 1
        roll_keep_for 24h
      }
      format transform `{request>remote_ip} - {request>user_id} [{ts}] "{request>method} {request>uri} {request>proto}" {status} {size} "{request>headers>Referer>[0]}" "{request>headers>User-Agent>[0]}"` {
        time_format "02/Jan/2006:15:04:05 -0700"
      }
    }
    @uptime_kuma header_regexp User-Agent ^Uptime-Kuma
    log_skip @uptime_kuma
  '';
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
          ${loggingConfig host}
          reverse_proxy :8081
        '';
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
                    -format=combined \
                    -site="https://${analyticsHost}" \
                    -exclude 'status:404' \
                    /var/log/caddy/access-${domain}.log
                '';
              };
            };
          }
        ) { } hostConfig.targets
      ) cfg.analyticsHosts)
    ];
  };
}

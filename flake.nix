# flake.nix
{
  description = "Chobble server configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    site-builder = {
      url = "git+https://git.chobble.com/chobble/nixos-site-builder";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils/11707dc2f618dd54ca8739b309ec4fc024de578b?narHash=sha256-l0KFg5HjrsfsO/JpG%2Br7fRrqm12kzFHyUHqHCVpMMbI%3D";
    caddy.url = "github:vincentbernat/caddy-nix/9d13eb684b4ba1b2eb92e76f7ea1f517eccc4fe1?narHash=sha256-kUWyjeqkU%2BRHTHVXT61QF19eW2vnWgah5OcPrUlU8oU%3D";
  };

  outputs =
    {
      self,
      nixpkgs,
      site-builder,
      flake-utils,
      caddy,
    }:
    let
      lib = nixpkgs.lib;
      shortHash = str: builtins.substring 0 8 (builtins.hashString "sha256" str);
    in
    {
      nixosModules.default =
        { config, pkgs, ... }:
        let
          cfg = config.services.chobble-server;

          customCaddy = (pkgs.extend caddy.overlays.default).caddy.withPlugins {
            plugins = [ "github.com/caddyserver/transform-encoder" ];
            hash = "sha256-9kgxIpIwC5asZ0PV8P6LO8HHVa3udHMSNNI/zV3lmAM=";
          };

          # These core services will always be monitored for failures
          baseServices = [
            # Git hosting service
            "forgejo"
            # Web server/reverse proxy
            "caddy"
            # Analytics
            "goatcounter"
            # Test service that always fails (for monitoring testing)
            "always-fails"
          ];

          # Get list of site builder services from the site-builder configuration.
          # Only included if site-builder is enabled.
          siteBuilderServices = lib.optionals config.services.site-builder.enable (
            map (domain: "site-${shortHash domain}-builder") (
              builtins.attrNames config.services.site-builder.sites
            )
          );

          # Complete list of all services that should be monitored
          monitoredServices = baseServices ++ siteBuilderServices;

          # Creates a monitoring configuration for a single service
          # Input: service name (like "forgejo")
          # Output: configuration that adds failure monitoring to that service
          monitorConfig =
            name:
            lib.nameValuePair name {
              unitConfig.OnFailure = [
                # %n is replaced with the service name by systemd
                "notify-failure@%n"
              ];
            };

          # Convert our list of services into a systemd-compatible attribute set
          # This adds failure monitoring to each service in monitoredServices
          monitoringConfigs = builtins.listToAttrs (map monitorConfig monitoredServices);

        in
        {
          imports = [
            ./analytics.nix # Import the analytics module here
          ];

          options.services.chobble-server = {
            enable = lib.mkEnableOption "Chobble server configuration";

            baseDomain = lib.mkOption {
              type = lib.types.str;
              example = "chobble.com";
              description = "Base domain for services";
            };

            hostname = lib.mkOption {
              type = lib.types.str;
              default = "chobble";
              description = "Server hostname";
            };

            myAddress = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Your IP address (for the firewall)";
            };

            sites = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    gitRepo = lib.mkOption {
                      type = lib.types.str;
                      description = "Git repository URL";
                    };
                    branch = lib.mkOption {
                      type = lib.types.str;
                      default = "main";
                      description = "Git branch to track";
                    };
                    wwwRedirect = lib.mkOption {
                      type = lib.types.bool;
                      default = false;
                      description = "Whether to redirect www subdomain";
                    };
                    useHTTPS = lib.mkOption {
                      type = lib.types.bool;
                      default = true;
                      description = "Whether to use HTTPS for this site";
                    };
                    host = lib.mkOption {
                      type = lib.types.enum [
                        "caddy"
                        "neocities"
                      ];
                      default = "caddy";
                      description = "Hosting service to use (caddy or neocities)";
                    };
                    builder = lib.mkOption {
                      type = lib.types.enum [
                        "nix"
                        "jekyll"
                      ];
                      default = "nix";
                      description = "Builder to use (nix or jekyll)";
                    };
                    apiKey = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "API key for the hosting service (if required)";
                    };
                  };
                }
              );
              default = { };
              description = "Static sites configuration";
            };
          };

          config = lib.mkIf cfg.enable {
            networking = {
              hostName = cfg.hostname;
              firewall = {
                enable = true;

                # Open ports for web traffic
                allowedTCPPorts = [
                  80 # HTTP
                  443 # HTTPS
                ];

                # Custom iptables rules to restrict SSH access to specific IP
                extraCommands = ''
                  # First, block all SSH connections by default
                  iptables -A INPUT -p tcp --dport 22 -j DROP

                  # Then, allow SSH only from this specific IP address
                  iptables -I INPUT \
                    -p tcp \
                    --dport 22 \
                    -s ${cfg.myAddress}/32 \
                    -j ACCEPT
                '';

                # Remove our custom rules when the firewall stops
                # The '|| true' ensures the script doesn't fail if rules don't exist
                extraStopCommands = ''
                  iptables -D INPUT -p tcp --dport 22 -j DROP || true
                  iptables -D INPUT \
                    -p tcp \
                    --dport 22 \
                    -s ${cfg.myAddress}/32 \
                    -j ACCEPT || true
                '';
              };
            };

            services.caddy = {
              enable = true;
              package = customCaddy;
              virtualHosts = {
                "git.${cfg.baseDomain}" = {
                  listenAddresses = [ "0.0.0.0" ];
                  extraConfig = ''
                    reverse_proxy :3000
                  '';
                };
              };
              globalConfig = ''
                @uptime_kuma header_regexp User-Agent Uptime-Kuma
                log_skip @uptime_kuma
              '';
            };

            services.forgejo = {
              enable = true;
              settings = {
                ui.DEFAULT_THEME = "forgejo-dark";
                DEFAULT = {
                  APP_NAME = "git.${cfg.baseDomain}";
                };
                server = {
                  DOMAIN = "git.${cfg.baseDomain}";
                  ROOT_URL = "https://git.${cfg.baseDomain}/";
                  LANDING_PAGE = "/explore/repos";
                  HTTP_PORT = 3000;
                };
                service.DISABLE_REGISTRATION = true;
                actions.ENABLED = false;
              };
            };

            services.goatcounter = {
              enable = true;
              proxy = true;
            };

            services.site-builder = {
              enable = true;
              inherit (cfg) sites;
            };

            systemd.services = lib.mkMerge [
              {
                # Template service for failure notifications
                "notify-failure@" = {
                  enable = true;
                  description = "Failure notification for %i";
                  scriptArgs = "%i"; # Pass the service name as an argument
                  # Send notification via ntfy.sh when a service fails
                  script = ''
                    NTFY_URL=$(cat /run/secrets/ntfy_url)
                    ${pkgs.curl}/bin/curl \
                      --fail \
                      --show-error --silent \
                      --max-time 10 \
                      --retry 3 \
                      --data "${config.networking.hostName} service '$1' exited with errors" \
                      "$NTFY_URL"
                  '';
                };

                # Test service that always fails (for testing)
                always-fails = {
                  description = "Always fails";
                  script = "exit 1";
                  serviceConfig.Type = "oneshot";
                };
              }

              monitoringConfigs
            ];

            services.openssh = {
              enable = true;
              allowSFTP = false;
              settings = {
                PermitRootLogin = "no";
                PasswordAuthentication = false;
              };
              extraConfig = ''
                AllowTcpForwarding yes
                X11Forwarding no
                AllowAgentForwarding no
                AllowStreamLocalForwarding no
                AuthenticationMethods publickey
                AddressFamily inet
              '';
            };

            # Remove default packages
            environment.defaultPackages = [ ];

            system.stateVersion = "23.05";
          };
        };

      # Example NixOS configuration
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          site-builder.nixosModules.default
          self.nixosModules.default
          {
            nixpkgs.overlays = [ caddy.overlays.default ];
          }
          (
            { modulesPath, ... }:
            {
              imports = [
                # This imports a basic virtual machine configuration
                (modulesPath + "/virtualisation/qemu-vm.nix")
              ];

              fileSystems."/" = {
                device = "test";
                fsType = "ext4";
              };

              services.chobble-server = {
                enable = true;
                baseDomain = "example.com";
                myAddress = "127.0.0.1";
                sites = {
                  "example.com" = {
                    gitRepo = "http://localhost:3000/example/site";
                    builder = "nix";
                    wwwRedirect = true;
                  };
                  "example.neocities.org" = {
                    gitRepo = "https://example.com/organisation/site";
                    builder = "nix";
                    wwwRedirect = false;
                    host = "neocities";
                    apiKey = "aaaaaaaaaaaaaa";
                  };
                };
              };
            }
          )
        ];
      };
    };
}

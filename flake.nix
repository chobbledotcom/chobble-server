{
  description = "Chobble server configuration";

  inputs = {
    nixpkgs.url = "nixpkgs";
    site-builder = {
      url = "git+https://git.chobble.com/chobble/nixos-site-builder";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      site-builder,
    }:
    let
      lib = nixpkgs.lib;
      shortHash = str: builtins.substring 0 8 (builtins.hashString "sha256" str);
    in
    {
      nixosModules.default =
        { config, pkgs, ... }:
        with lib;
        let
          cfg = config.services.chobble-server;

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
            ./analytics.nix
            ./redirects.nix
          ];

          options.services.chobble-server = {
            enable = lib.mkEnableOption "Chobble server configuration";

            baseDomain = mkOption {
              type = types.str;
              example = "chobble.com";
              description = "Base domain for services";
            };
            hostname = mkOption {
              type = types.str;
              default = "chobble";
              description = "Server hostname";
            };
            sites = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    gitRepo = mkOption {
                      type = types.str;
                      description = "Git repository URL";
                    };
                    branch = mkOption {
                      type = types.str;
                      default = "main";
                      description = "Git branch to track";
                    };
                    wwwRedirect = mkOption {
                      type = types.bool;
                      default = false;
                      description = "Whether to redirect www subdomain";
                    };
                    useHTTPS = mkOption {
                      type = types.bool;
                      default = true;
                      description = "Whether to use HTTPS for this site";
                    };
                    host = mkOption {
                      type = types.enum [
                        "caddy"
                        "neocities"
                      ];
                      default = "caddy";
                      description = "Hosting service to use (caddy or neocities)";
                    };
                    subfolder = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Subfolder within the repository to use as the site root";
                      example = "public";
                    };
                    builder = mkOption {
                      type = types.enum [
                        "nix"
                        "jekyll"
                      ];
                      default = "nix";
                      description = "Builder to use (nix or jekyll)";
                    };
                    apiKey = mkOption {
                      type = types.nullOr types.str;
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
                  22 # SSH
                  80 # HTTP
                  443 # HTTPS
                ];
              };
            };

            services.caddy = {
              enable = true;
              virtualHosts = {
                "git.${cfg.baseDomain}" = {
                  listenAddresses = [ "0.0.0.0" ];
                  extraConfig = ''
                    @commits `{path}.contains("/commit/") || {path}.contains("/commits/") || {path}.contains("/compare/") || {path}.contains("/blame/") || {path}.startsWith("/.within.website")`

                    reverse_proxy @commits :8923 {
                      header_up X-Real-IP {remote_host}
                      header_down "X-Robots-Tag" "noindex, nofollow"
                    }

                    reverse_proxy :3000 {
                      header_up X-Real-IP {remote_host}
                    }
                  '';
                  logFormat = ''
                    output file /var/log/caddy/git.${cfg.baseDomain}.log {
                      roll_size 100mb
                      roll_keep 7
                      roll_keep_for 24h
                    }
                  '';
                };
              };
            };

            virtualisation.oci-containers.containers.anubis-git = {
              image = "ghcr.io/xe/x/anubis:latest";
              environment = {
                DIFFICULTY = "3";
                SERVE_ROBOTS_TXT = "true";
                TARGET = "http://localhost:3000";
              };
              extraOptions = [
                "--pull=newer"
                "--network=host"
              ];
            };

            services.forgejo = {
              enable = true;
              package = pkgs.forgejo;
              settings = {
                ui.DEFAULT_THEME = "forgejo-dark";
                DEFAULT = {
                  APP_NAME = "git.${cfg.baseDomain}";
                };
                cors = {
                  ENABLED = true;
                  ALLOW_DOMAIN = "*.${cfg.baseDomain}";
                };
                server = {
                  DOMAIN = "git.${cfg.baseDomain}";
                  ROOT_URL = "https://git.${cfg.baseDomain}/";
                  LANDING_PAGE = "/explore/repos";
                  HTTP_PORT = 3000;
                };
                service.DISABLE_REGISTRATION = true;
                actions = {
                  ENABLED = true;
                  DEFAULT_ACTIONS_URL = "github";
                };
              };
            };

            services.goatcounter = {
              enable = true;
              proxy = true;
            };

            services.site-builder = {
              enable = builtins.length (builtins.attrNames cfg.sites) > 0;
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
            nixpkgs.overlays = [ ];
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

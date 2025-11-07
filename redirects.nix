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
        "http://specific.example.com" = "https://specific.example.com";
      };
      description = ''
        Domain redirect configuration where each key is the source domain
        and the value is the destination URL for 301 redirects.
        
        If the key starts with http:// or https://, only that specific protocol
        version will be created. Otherwise, both HTTP and HTTPS versions are created.
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
          
          # Check if domain already has a protocol prefix
          hasHttpPrefix = lib.hasPrefix "http://" domain;
          hasHttpsPrefix = lib.hasPrefix "https://" domain;
          hasProtocol = hasHttpPrefix || hasHttpsPrefix;
          
          # If domain has protocol, use it as-is; otherwise strip any protocol and use bare domain
          cleanDomain = if hasProtocol then domain else lib.removePrefix "https://" (lib.removePrefix "http://" domain);
        in
        if hasProtocol then
          # Only create the specific protocol version
          {
            "${cleanDomain}" = {
              extraConfig = ''
                redir ${redirectTarget} 301
              '';
              logFormat = "output discard";
            };
          }
        else
          # Create both HTTP and HTTPS versions
          {
            "http://${domain}" = {
              extraConfig = ''
                redir ${redirectTarget} 301
              '';
              logFormat = "output discard";
            };
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

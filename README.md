# chobble-server

A NixOS module for running a server with Forgejo (git hosting), Caddy (reverse proxy), and static site hosting.

## Features

- Git hosting with Forgejo
- Reverse proxy with Caddy
- Static site hosting with automated builds
- Service monitoring with failure notifications via ntfy.sh
- Restricted SSH access by IP

## Usage

Add to your flake inputs:

```nix
{
  inputs.chobble-server.url = "git+https://git.chobble.com/chobble/chobble-server";
}
```

Basic config example:

```nix
{
  imports = [ chobble-server.nixosModules.default ];

  services.chobble-server = {
    enable = true;
    baseDomain = "example.com";          # Your domain name
    myAddress = "1.2.3.4";               # Your IP (for SSH access)

    # Static sites to host
    sites = {
      "example.com" = {
        gitRepo = "http://localhost:3000/user/site";
        wwwRedirect = true;
      };
      "blog.example.com" = {
        gitRepo = "http://localhost:3000/user/blog";
        wwwRedirect = false;
      };
    };
  };
}
```

Options

- **enable** - Enable the chobble-server configuration
- **baseDomain** - Base domain for services (git will be hosted at git.basedomain)
- **ntfyAddress** - ntfy.sh address for service failure notifications
- **myAddress** - Your IP address (SSH access will be restricted to this IP)
- **sites** - Attrset of static sites to host
- **gitRepo** - Git repository URL
- **wwwRedirect** - Whether to redirect www subdomain
- **useHTTPS** - Whether to use HTTPS (default: true)
- **host** - Hosting service to use ("caddy" or "neocities", default: "caddy")
- **apiKey** - API key for the hosting service (if required)

# nixpkgs-nodejs

All Node.js versions, kept up-to-date automatically using Nix.

Inspired by [nixpkgs-terraform](https://github.com/stackbuilders/nixpkgs-terraform), [nixpkgs-python](https://github.com/cachix/nixpkgs-python), and [nixpkgs-ruby](https://github.com/bobvanderlinden/nixpkgs-ruby).

## Features

- 🔄 **Automatic Updates**: Automatic updates via GitHub Actions
- 📦 **Binary Cache**: Pre-built packages via Cachix
- 🎯 **Version Precision**: Access any Node.js version from 16.0.0+
- 🔒 **Reproducible**: Locked to specific nixpkgs commits

## Usage

### With Flakes

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-nodejs.url = "github:davidnbr/nixpkgs-nodejs";
  };

  outputs = { self, nixpkgs, nixpkgs-nodejs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
    devShells.${system}.default = pkgs.mkShell {
        packages = [
          nixpkgs-nodejs.packages.${system}.nodejs_22_22
          # Or if you need yarn specifically linked to that node
          # nixpkgs-nodejs.packages.${system}.yarn_22_22
        ];
      };
    };
}
```

### Ad-hoc Shell

```bash
# Get Node.js + NPM
nix shell github:davidnbr/nixpkgs-nodejs#nodejs_22_22

# Get Node.js + Yarn (bundled)
nix shell github:davidnbr/nixpkgs-nodejs#yarn_22_22

# Get Node.js + Pnpm (bundled)
nix shell github:davidnbr/nixpkgs-nodejs#pnpm_22_22
```

### Using as an Overlay

You can integrate these versions directly into your `nixpkgs` set using the provided overlay:

```nix
{
  inputs.nixpkgs-nodejs.url = "github:davidnbr/nixpkgs-nodejs";
  
  outputs = { self, nixpkgs, nixpkgs-nodejs }: {
    pkgs = import nixpkgs {
      system = "x86_64-linux";
      overlays = [ nixpkgs-nodejs.overlays.default ];
    };
    
    # Now you can use them like standard packages
    # pkgs.nodejs_22_22
    # pkgs.yarn_22_22
  };
}
```

### Formatting

This flake provides a formatter for your Nix code:

```bash
nix fmt
```

### List Available Versions

```bash
nix flake show github:davidnbr/nixpkgs-nodejs
```

## Binary Cache

Add to your `flake.nix`:

```nix
nixConfig = {
  extra-substituters = ["https://nixpkgs-nodejs.cachix.org"];
  extra-trusted-public-keys = [
    "nixpkgs-nodejs.cachix.org-1:zUIFXIRHGVtNSAhYWPDOIpr/4hAvhUEfcRo78RWDgiI="
  ];
};
```

Or configure globally in `~/.config/nix/nix.conf`:

```
extra-substituters = https://nixpkgs-nodejs.cachix.org
extra-trusted-public-keys = nixpkgs-nodejs.cachix.org-1:YzUIFXIRHGVtNSAhYWPDOIpr/4hAvhUEfcRo78RWDgiI=
```

## Development

Build a specific version:

```bash
nix build .#"20.11.0"
```

## License

MIT

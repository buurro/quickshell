# quickshell

> [!CAUTION]
> This project is largely AI-generated and may contain bugs or unexpected behavior. Use at your own risk and review the code before relying on it.

Generate standalone, multi-arch shell scripts that fetch packages from binary caches - no Nix evaluation at runtime.

## Why?

`nix develop` and `nix shell` are slow because they evaluate Nix expressions every time. This is painful for:

- CI/CD pipelines
- Onboarding teammates unfamiliar with Nix
- Quick shell access without waiting

## How it works

1. You define packages in a flake
2. Run `nix run .#dev > scripts/dev.sh` to generate a bash script
3. The script fetches pre-built packages from binary caches and sets up your shell
4. Commit the script - anyone with Nix can use it instantly

The generated script works on all architectures: `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, `x86_64-linux`.

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    quickshell.url = "github:buurro/quickshell";
  };

  outputs = { nixpkgs, quickshell, ... }: {
    packages = quickshell.lib.mkPackages nixpkgs {
      dev = pkgs: with pkgs; [
        nodejs
        python3
        jq
      ];
    };
  };
}
```

Then:

```bash
nix run .#dev                    # Print script to stdout
nix run .#dev > scripts/dev.sh   # Save to file
chmod +x scripts/dev.sh

nix shell .#dev                  # Use packages directly via nix
./scripts/dev.sh                 # Use the generated script (fast, no nix eval!)
```

## Multiple shells

```nix
packages = quickshell.lib.mkPackages nixpkgs {
  dev = pkgs: with pkgs; [ nodejs python3 ];
  frontend = pkgs: with pkgs; [ nodejs pnpm ];
};
```

## Options

For simple cases, each shell is just a function `pkgs -> [ packages ]`.

For advanced options, use an attrset:

```nix
packages = quickshell.lib.mkPackages nixpkgs {
  dev = {
    packages = pkgs: with pkgs; [ nodejs python3 ];
    caches = [ "s3://my-bucket" "https://cache.nixos.org" ];
    systems = [ "x86_64-linux" "aarch64-linux" ];  # linux only
    nixpkgs = other-nixpkgs;  # override nixpkgs for this shell
  };
};
```

| Option     | Required | Default                       | Description                       |
| ---------- | -------- | ----------------------------- | --------------------------------- |
| `packages` | yes      | -                             | Function: `pkgs -> [ packages ]`  |
| `caches`   | no       | `["https://cache.nixos.org"]` | Binary caches to fetch from       |
| `systems`  | no       | all 4 systems                 | Which architectures to support    |
| `nixpkgs`  | no       | inherited from `mkPackages`   | Override nixpkgs for this shell   |
| `comment`  | no       | `""`                          | Comment added to generated script |

## Custom packages / private caches

For packages not in cache.nixos.org, push them to your own cache:

```bash
nix build .#dev
nix copy --to s3://my-bucket .#dev
```

Then add your cache:

```nix
packages = quickshell.lib.mkPackages nixpkgs {
  dev = {
    packages = pkgs: [ pkgs.my-custom-package ];
    caches = [
      "https://cache.nixos.org"
      "s3://my-bucket"
    ];
  };
};
```

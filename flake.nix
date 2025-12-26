{
  outputs = {...}: let
    defaultSystems = [
      "aarch64-darwin"
      "x86_64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];

    # Map nix system to uname output
    systemToUname = {
      "aarch64-darwin" = "Darwin-arm64";
      "x86_64-darwin" = "Darwin-x86_64";
      "aarch64-linux" = "Linux-aarch64";
      "x86_64-linux" = "Linux-x86_64";
    };

    # Core library function to create a devshell definition
    mkDevshell = {
      nixpkgs,
      packagesFor,
      caches ? ["https://cache.nixos.org"],
      systems ? defaultSystems,
      comment ? "",
    }: {
      # Store config for toPackages to use
      _type = "quickshell";
      _config = {inherit nixpkgs packagesFor caches systems comment;};
    };

    # Convert devshell definitions to flake packages
    # Usage: packages = toPackages { dev = myDevshell; frontend = otherShell; };
    toPackages = shells: let
      # Get all systems from all shells (use first shell's systems as reference)
      firstShell = builtins.head (builtins.attrValues shells);
      systems = firstShell._config.systems;

      # Build outputs for a single shell with a given name
      mkShellOutputs = name: shell: let
        cfg = shell._config;
        nixpkgs = cfg.nixpkgs;

        perSystem = builtins.listToAttrs (map (system: let
            pkgs = nixpkgs.legacyPackages.${system};
            packages = cfg.packagesFor pkgs;
            outPaths = map (p: builtins.unsafeDiscardStringContext (toString p)) packages;
            copyPaths = builtins.concatStringsSep " " outPaths;
            binPaths = builtins.concatStringsSep ":" (map (p: "${p}/bin") outPaths);
            packageInfo = map (p: "${p.pname or p.name} ${p.version or ""}") packages;
          in {
            name = system;
            value = {inherit pkgs packages outPaths copyPaths binPaths packageInfo;};
          })
          cfg.systems);

        firstSystem = builtins.head cfg.systems;
        caseBranches = builtins.concatStringsSep "\n" (map (system: let
          info = perSystem.${system};
          uname = systemToUname.${system};
        in ''
          ${uname})
            copy_paths="${info.copyPaths}"
            bin_paths="${info.binPaths}"
            ;;'')
        cfg.systems);

        copyCmds = builtins.concatStringsSep "\n" (
          map (cache: ''nix --extra-experimental-features 'nix-command' copy --from ${cache} $copy_paths || true'') cfg.caches
        );

        missingCheck = ''
          missing=()
          for p in $copy_paths; do
            if [ ! -e "$p" ]; then
              missing+=("$p")
            fi
          done
          if [ ''${#missing[@]} -gt 0 ]; then
            echo "ERROR: Missing packages not found in any cache:" >&2
            printf '  %s\n' "''${missing[@]}" >&2
            exit 1
          fi
        '';

        # Sanitize comment: split lines and prefix each with #
        # This prevents injection even if comment contains newlines or special chars
        sanitizedComment =
          if cfg.comment != ""
          then let
            # builtins.split returns interleaved [string, match, string, match, ...]
            # Filter to keep only strings (non-lists)
            lines = builtins.filter builtins.isString (builtins.split "\n" cfg.comment);
            cleanLines = map (line: builtins.replaceStrings ["\r"] [""] line) lines;
          in
            builtins.concatStringsSep "\n" (map (line: "# ${line}") cleanLines) + "\n"
          else "";

        scriptContent = ''
          #!/usr/bin/env bash

          ${sanitizedComment}
          PACKAGES="
          ${builtins.concatStringsSep "\n" perSystem.${firstSystem}.packageInfo}
          "

          set -euo pipefail

          # Detect system
          case "$(uname -s)-$(uname -m)" in
          ${caseBranches}
            *)
              echo "Unsupported system: $(uname -s)-$(uname -m)"
              exit 1
              ;;
          esac

          ${copyCmds}

          ${missingCheck}

          echo "Packages:$PACKAGES"

          # CI mode: set up PATH for GitHub Actions and exit
          if [ "''${GITHUB_ACTIONS:-}" = "true" ]; then
            echo "$bin_paths" | tr ':' '\n' >> "$GITHUB_PATH"
            exit 0
          fi

          export IN_NIX_SHELL=impure
          export name="${name}"
          export PATH="$bin_paths:$PATH"

          exec "''${SHELL:-/bin/bash}"
        '';

        mkSystemOutputs = system: let
          info = perSystem.${system};

          # Create the generator script (prints to stdout)
          generatorScript = info.pkgs.writeShellScript "generate-${name}-script" ''
            cat << 'EOF'
            ${scriptContent}
            EOF
          '';

          # Create a package that:
          # - Has all binaries from packages (for nix shell)
          # - Has a main program that generates the script (for nix run)
          shellPackage = info.pkgs.symlinkJoin {
            name = name;
            paths = info.packages;
            postBuild = ''
              # Add the generator as the main program
              cp ${generatorScript} $out/bin/${name}
            '';
            meta.mainProgram = name;
          };
        in {
          ${name} = shellPackage;
        };
      in
        builtins.listToAttrs (map (system: {
            name = system;
            value = mkSystemOutputs system;
          })
          cfg.systems);

      # Merge all shells' outputs per system
      allOutputs = builtins.mapAttrs (name: shell: mkShellOutputs name shell) shells;
    in
      builtins.listToAttrs (map (system: {
          name = system;
          value = builtins.foldl' (acc: shellOutputs: acc // shellOutputs.${system}) {} (builtins.attrValues allOutputs);
        })
        systems);

    # Helper to generate for all systems (for simple per-system outputs)
    forAllSystems = nixpkgs: f:
      builtins.listToAttrs (map (system: {
          name = system;
          value = f nixpkgs.legacyPackages.${system};
        })
        defaultSystems);
  in {
    lib = {inherit mkDevshell toPackages forAllSystems;};
  };
}

{
  outputs = {...}: let
    defaultSystems = ["aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux"];

    systemToUname = {
      "aarch64-darwin" = "Darwin-arm64";
      "x86_64-darwin" = "Darwin-x86_64";
      "aarch64-linux" = "Linux-aarch64";
      "x86_64-linux" = "Linux-x86_64";
    };

    getUname = system:
      systemToUname.${system}
      or (throw "Unsupported system '${system}'. Add it to systemToUname.");

    escapeForBash = s:
      builtins.replaceStrings ["\\" "\"" "$" "`"] ["\\\\" "\\\"" "\\$" "\\`"] s;

    # Sanitize comment for safe embedding in bash script
    # Splits on newlines and prefixes each line with "# " to ensure
    # all content is a bash comment (no injection possible)
    sanitizeComment = comment:
      if comment == ""
      then ""
      else let
        # builtins.split returns interleaved [string, match, string, ...]
        parts = builtins.split "\n" comment;
        lines = builtins.filter builtins.isString parts;
        clean = map (builtins.replaceStrings ["\r"] [""]) lines;
      in
        builtins.concatStringsSep "\n" (map (line: "# ${line}") clean) + "\n";

    # Main API: mkPackages nixpkgs { name = packagesFunc | config; ... }
    mkPackages = nixpkgs: shells: let
      # Normalize: function -> { packages = fn; }, attrset stays as-is
      normalize = shell:
        if builtins.isFunction shell
        then {packages = shell;}
        else shell;

      configs = builtins.mapAttrs (_: normalize) shells;

      # Collect all unique systems
      allSystems = builtins.foldl' (
        acc: cfg:
          acc ++ builtins.filter (s: !builtins.elem s acc) (cfg.systems or defaultSystems)
      ) [] (builtins.attrValues configs);

      # Generate script content for a shell
      mkScript = name: cfg: system: let
        pkgs = (cfg.nixpkgs or nixpkgs).legacyPackages.${system};
        packages = cfg.packages pkgs;
        caches = cfg.caches or ["https://cache.nixos.org"];
        systems = cfg.systems or defaultSystems;
        comment = sanitizeComment (cfg.comment or "");

        pkgInfo = map (p: escapeForBash "${p.pname or p.name} ${p.version or ""}") packages;

        caseBranches = builtins.concatStringsSep "\n" (map (sys: let
          sysInfo = let
            p = (cfg.nixpkgs or nixpkgs).legacyPackages.${sys};
            pkgList = cfg.packages p;
            sPaths = map (pkg: builtins.unsafeDiscardStringContext (toString pkg)) pkgList;
          in {
            paths = builtins.concatStringsSep " " sPaths;
            bins = builtins.concatStringsSep ":" (map (pkg: "${pkg}/bin") sPaths);
          };
        in ''
          ${getUname sys})
            copy_paths="${sysInfo.paths}"
            bin_paths="${sysInfo.bins}"
            ;;'')
        systems);

        copyCmds = builtins.concatStringsSep "\n" (
          map (c: ''nix --extra-experimental-features 'nix-command' copy --from ${c} $copy_paths || true'') caches
        );
      in ''
        #!/usr/bin/env bash
        ${comment}PACKAGES="
        ${builtins.concatStringsSep "\n" pkgInfo}
        "

        set -euo pipefail

        case "$(uname -s)-$(uname -m)" in
        ${caseBranches}
          *)
            echo "Unsupported system: $(uname -s)-$(uname -m)" >&2
            exit 1
            ;;
        esac

        ${copyCmds}

        # Check all packages exist
        missing=()
        for p in $copy_paths; do
          [ -e "$p" ] || missing+=("$p")
        done
        if [ ''${#missing[@]} -gt 0 ]; then
          echo "ERROR: Missing packages:" >&2
          printf '  %s\n' "''${missing[@]}" >&2
          exit 1
        fi

        echo "Packages:$PACKAGES"

        # GitHub Actions: add to PATH and exit
        if [ "''${GITHUB_ACTIONS:-}" = "true" ]; then
          echo "$bin_paths" | tr ':' '\n' >> "$GITHUB_PATH"
          exit 0
        fi

        export IN_NIX_SHELL=impure
        export name="${name}"
        export PATH="$bin_paths:$PATH"
        exec "''${SHELL:-/bin/bash}"
      '';

      # Build shell package for a system
      mkShellPkg = name: cfg: system: let
        pkgs = (cfg.nixpkgs or nixpkgs).legacyPackages.${system};
        packages = cfg.packages pkgs;
        script = mkScript name cfg system;
        scriptFile = pkgs.writeText "${name}-script" script;
        generator = pkgs.writeShellScript "generate-${name}" "cat ${scriptFile}";
      in
        pkgs.symlinkJoin {
          inherit name;
          paths = packages;
          postBuild = "cp ${generator} $out/bin/${name}";
          meta.mainProgram = name;
        };
    in
      builtins.listToAttrs (map (system: {
          name = system;
          value =
            builtins.foldl' (
              acc: entry: let
                name = entry.name;
                cfg = entry.value;
                systems = cfg.systems or defaultSystems;
              in
                if builtins.elem system systems
                then acc // {${name} = mkShellPkg name cfg system;}
                else acc
            ) {} (builtins.map (name: {
              inherit name;
              value = configs.${name};
            }) (builtins.attrNames configs));
        })
        allSystems);
  in {
    lib = {inherit mkPackages;};

    templates.default = {
      path = ./templates/default;
      description = "Quickshell project template";
    };
  };
}

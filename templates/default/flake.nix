{
  description = "Example project using quickshell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # For users: use github:buurro/quickshell
    # This uses parent dir for local testing
    quickshell.url = "path:../..";
  };

  outputs = {
    nixpkgs,
    quickshell,
    ...
  }: {
    packages = quickshell.lib.mkPackages nixpkgs {
      # Simple syntax: just a function
      dev = pkgs:
        with pkgs; [
          jq
          curl
          git
          ty
        ];

      # With comment (single line)
      with-comment = {
        packages = pkgs: [pkgs.hello];
        comment = "This is a dev environment";
      };

      # With multiline comment
      with-multiline-comment = {
        packages = pkgs: [pkgs.hello];
        comment = ''
          Development environment
          Created by quickshell
        '';
      };

      # Comment with potentially dangerous characters (should be safely escaped)
      with-dangerous-comment = {
        packages = pkgs: [pkgs.hello];
        comment = ''
          Test: $(whoami) `id` $HOME
          Backslash at end: \
          Quotes: "hello" 'world'
        '';
      };

      # Advanced syntax: attrset with options
      ci = {
        packages = pkgs:
          with pkgs; [
            jq
            curl
          ];
        systems = ["x86_64-linux" "aarch64-linux"];
      };
    };
  };
}

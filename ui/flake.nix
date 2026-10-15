{
  description = "Dufs: pure-QML Basecamp view over the dufs_core module";

  inputs = {
    # Same builder as the core (Basecamp 0.3.x).
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.1";
    # A GitHub ref, not path:../core: a relative path lock breaks a clean clone on some Nix versions.
    # The view only needs the core's interface (LIDL), so this pins the commit that defines it.
    dufs_core.url = "github:vpavlin/dufs-basecamp/afe5ee07a53e8a95dfa9b38454701e26bdf1756e?dir=core";
    dufs_core.inputs.logos-module-builder.follows = "logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}

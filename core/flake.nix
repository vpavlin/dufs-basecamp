{
  description = "dufs_core: Basecamp core module that talks to dufs file servers";

  inputs = {
    # Basecamp 0.3.x: builder 0.3.1 (release tag).
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.1";
    # Logos Storage (the host's node on Basecamp 0.3). Pinned: master once pulled in an API break.
    # v3.0.1's API is the one 3.0.2 and the 3.0.3 fork (libstorage download fix) have too.
    storage_module.url = "github:logos-co/logos-storage-module/v3.0.1";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}

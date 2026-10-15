{
  description = "dufs_core: Basecamp core module that talks to dufs file servers";

  inputs = {
    # Basecamp 0.3.x: builder 0.3.1 (release tag).
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.1";
    # Logos Storage (the host's node on Basecamp 0.3). Pinned: master once pulled in an API break.
    # v3.0.1's API is the one 3.0.2 and the 3.0.3 fork (libstorage download fix) have too.
    storage_module.url = "github:logos-co/logos-storage-module/v3.0.1";
    # The same API, served by a Storage node elsewhere (its REST API): Settings → Storage node.
    storage_gateway.url = "github:vpavlin/logos-storage-gateway/b1f7199ea16e5ba8132a3b4e7cfac7e973f549f6?dir=module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}

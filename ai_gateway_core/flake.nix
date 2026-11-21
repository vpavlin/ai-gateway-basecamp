{
  description = "AI Gateway CORE module: one OpenAI-compatible way in to local and private AI for Logos apps (Basecamp 0.3).";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/3a64943fe6827bab4c4686fb35c37d24d5df0710";   # tag 0.3.3 (pairs with Basecamp 0.3.2), pinned to its commit
  };

  # mkLogosModule: a headless core module; the plugin glue is generated from
  # src/ai_gateway_core_impl.h (universal authoring).
  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}

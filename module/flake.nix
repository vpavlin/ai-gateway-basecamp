{
  description = "AI Gateway Basecamp ui_qml module: a pure QML view over ai_gateway_core, and the provider of the ai.ask / ai.chat intents (Basecamp 0.3).";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/3a64943fe6827bab4c4686fb35c37d24d5df0710";   # tag 0.3.3 (pairs with Basecamp 0.3.2), pinned to its commit
    ai_gateway_core.url = "path:../ai_gateway_core";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}

import type { GlobalSetupContext } from "vitest/node";
import { spawnAnvil, deployContracts, type DeployedAddresses } from "./deploy";

declare module "vitest" {
  export interface ProvidedContext {
    anvilRpcUrl: string;
    deployed: DeployedAddresses;
  }
}

export async function setup(ctx: GlobalSetupContext) {
  const anvil = await spawnAnvil();
  const deployed = deployContracts(anvil.rpcUrl);

  ctx.provide("anvilRpcUrl", anvil.rpcUrl);
  ctx.provide("deployed", deployed);

  return async () => {
    anvil.stop();
  };
}

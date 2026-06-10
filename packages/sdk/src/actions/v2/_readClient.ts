import type { PublicClient } from "viem";
import type { ArcoraDexAddresses } from "../../addresses";

export interface ReadClientV2 {
  publicClient: PublicClient;
  addresses: ArcoraDexAddresses;
}

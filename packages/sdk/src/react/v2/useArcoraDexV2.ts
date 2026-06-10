"use client";
import type { ArcoraDexClientV2 } from "../../clientV2";
import { useArcoraDexV2Context } from "./ArcoraDexV2Provider";

/** Returns the V2 SDK instance from context. Throws if called outside <ArcoraDexV2Provider>. */
export function useArcoraDexV2(): ArcoraDexClientV2 {
  const sdk = useArcoraDexV2Context();
  if (!sdk) {
    throw new Error(
      "useArcoraDexV2 must be called inside <ArcoraDexV2Provider>, with a wagmi PublicClient available.",
    );
  }
  return sdk;
}

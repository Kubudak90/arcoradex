"use client";
import type { ArcoraDexClient } from "../client";
import { useArcoraDexContext } from "./ArcoraDexProvider";

/** Returns the SDK instance from context. Throws if called outside <ArcoraDexProvider>. */
export function useArcoraDex(): ArcoraDexClient {
  const sdk = useArcoraDexContext();
  if (!sdk) {
    throw new Error(
      "useArcoraDex must be called inside <ArcoraDexProvider>, with a wagmi PublicClient available.",
    );
  }
  return sdk;
}

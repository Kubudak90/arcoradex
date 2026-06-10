"use client";
import { useSyncExternalStore } from "react";

/**
 * A tiny, dependency-free toast store (replaces `sonner`). A module-level array
 * + a `Set` of subscribers, surfaced via `useSyncExternalStore`. The swap /
 * deposit / withdraw flows call `pushToast` with a success/error kind plus an
 * optional tx hash; the `<Toasts>` host renders a BaseScan link from it.
 *
 * Toasts auto-dismiss after `TTL_MS`; `dismiss(id)` removes one early.
 */
export type ToastKind = "success" | "info" | "error";

export interface Toast {
  id: number;
  kind: ToastKind;
  title: string;
  msg?: string;
  /** A tx hash — rendered as a BaseScan link in the toast. */
  hash?: `0x${string}`;
}

export type ToastInput = Omit<Toast, "id">;

const TTL_MS = 5200;

let toasts: Toast[] = [];
const subscribers = new Set<() => void>();
let nextId = 1;

function emit() {
  // New array reference so `useSyncExternalStore`'s identity check fires.
  toasts = toasts.slice();
  subscribers.forEach((fn) => fn());
}

function subscribe(fn: () => void): () => void {
  subscribers.add(fn);
  return () => subscribers.delete(fn);
}

function getSnapshot(): Toast[] {
  return toasts;
}

// Stable empty snapshot for SSR (must be referentially stable across calls).
const EMPTY: Toast[] = [];
function getServerSnapshot(): Toast[] {
  return EMPTY;
}

/** Push a toast; auto-dismisses after the TTL. Returns its id. */
export function pushToast(input: ToastInput): number {
  const id = nextId++;
  toasts = [...toasts, { ...input, id }];
  emit();
  if (typeof window !== "undefined") {
    window.setTimeout(() => dismiss(id), TTL_MS);
  }
  return id;
}

/** Remove a toast early. */
export function dismiss(id: number): void {
  toasts = toasts.filter((t) => t.id !== id);
  emit();
}

/** Subscribe a component to the live toast list. */
export function useToasts(): Toast[] {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}

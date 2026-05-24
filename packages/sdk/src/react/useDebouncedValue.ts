"use client";
// M-7 (audit 2026-05-24): the directive was missing — every other hook in
// this directory carries it, and an RSC import path that pulls this module
// would crash at runtime (`useState`/`useEffect` are client-only).
import { useEffect, useState } from "react";

export function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    if (delayMs <= 0) {
      setDebounced(value);
      return;
    }
    const id = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(id);
  }, [value, delayMs]);
  return debounced;
}

"use client";
import { useEffect, useState } from "react";

const STORAGE_KEY = "arcoradex-theme";

/**
 * Theme hook for the header toggle. The default is dark (set as
 * `data-theme="dark"` on `<html>` in layout.tsx); this reads/sets
 * `document.documentElement.dataset.theme` and persists the choice to
 * localStorage so it survives reloads.
 *
 * It hydrates from the stored preference on mount (after SSR painted the
 * dark default) — a one-frame correction, no theme flash for the default.
 */
export function useTheme(): { dark: boolean; toggle: () => void } {
  const [dark, setDark] = useState(true);

  // Hydrate from localStorage / the current DOM attribute on mount.
  useEffect(() => {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    const initial = stored
      ? stored === "dark"
      : document.documentElement.dataset.theme !== "light";
    setDark(initial);
    document.documentElement.dataset.theme = initial ? "dark" : "light";
  }, []);

  function toggle() {
    setDark((prev) => {
      const next = !prev;
      const theme = next ? "dark" : "light";
      document.documentElement.dataset.theme = theme;
      window.localStorage.setItem(STORAGE_KEY, theme);
      return next;
    });
  }

  return { dark, toggle };
}

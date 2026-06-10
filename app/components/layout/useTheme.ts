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

  // Hydrate from localStorage / the current DOM attribute on mount. This is a
  // post-SSR external-system sync (read the persisted theme, reconcile the
  // <html> attribute) — the one allowed setState-in-effect shape.
  useEffect(() => {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    const initial = stored
      ? stored === "dark"
      : document.documentElement.dataset.theme !== "light";
    // eslint-disable-next-line react-hooks/set-state-in-effect -- hydration reconcile after SSR paint
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

import type { CSSProperties } from "react";

/**
 * Single-stroke (~1.75, rounded) icon set — the DS iconography spec, ported
 * verbatim from the prototype's ui.jsx. Replaces Material Symbols; every glyph
 * is inline SVG path data rendered with `currentColor`.
 */
export const ICONS = {
  swap: '<path d="M7 4v13M7 17l-3-3M7 17l3-3"/><path d="M17 20V7M17 7l-3 3M17 7l3 3"/>',
  chevronDown: '<path d="M5 8l5 5 5-5" transform="translate(2 1.5)"/>',
  chevronRight: '<path d="M9 6l6 6-6 6"/>',
  close: '<path d="M6 6l12 12M18 6L6 18"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4-4"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  minus: '<path d="M5 12h14"/>',
  check: '<path d="M5 13l4 4L19 7"/>',
  checkCircle: '<circle cx="12" cy="12" r="9"/><path d="M8.5 12.5l2.5 2.5 4.5-5"/>',
  arrowRight: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  arrowDown: '<path d="M12 5v14M6 13l6 6 6-6"/>',
  external:
    '<path d="M14 5h5v5"/><path d="M19 5l-8 8"/><path d="M18 13v5a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
  trending: '<path d="M3 17l6-6 4 4 7-7"/><path d="M17 8h4v4"/>',
  activity: '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
  copy: '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h8"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
  zap: '<path d="M13 3L5 14h6l-1 7 8-11h-6z"/>',
  layers: '<path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/>',
  shield: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  moon: '<path d="M20 14a8 8 0 1 1-9.5-9.8A7 7 0 0 0 20 14z"/>',
  settings:
    '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2.4"/><circle cx="8" cy="17" r="2.4"/>',
  fuel: '<path d="M5 21V5a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v16"/><path d="M3 21h14"/><path d="M15 8h2.5a1.5 1.5 0 0 1 1.5 1.5V16a2 2 0 0 0 2 2v0a2 2 0 0 0 2-2V9l-3-3"/><path d="M8 8h4"/>',
  droplet: '<path d="M12 3s6 6 6 10a6 6 0 0 1-12 0c0-4 6-10 6-10z"/>',
  wallet:
    '<path d="M3 7a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v0H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2"/><circle cx="17" cy="13" r="1.2"/>',
  refresh:
    '<path d="M3 10a8 8 0 0 1 13.5-4L20 9M21 5v4h-4"/><path d="M21 14a8 8 0 0 1-13.5 4L4 15M3 19v-4h4"/>',
  link: '<path d="M9 13a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1.5 1.5"/><path d="M15 11a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1.5-1.5"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>',
  flame: '<path d="M12 3c1 3 4 4 4 8a4 4 0 0 1-8 0c0-1 .5-2 1-2.5C9 11 12 9 12 3z"/>',
  lock: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  dots: '<circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/>',
  gauge: '<path d="M4 18a8 8 0 1 1 16 0"/><path d="M12 14l4-4"/>',
  scale:
    '<path d="M12 3v18M5 7h14M7 7l-3 6h6zM17 7l-3 6h6z"/><path d="M2 13a4 4 0 0 0 8 0M14 13a4 4 0 0 0 8 0"/>',
} as const;

export type IconName = keyof typeof ICONS;

export function Icon({
  name,
  size = 18,
  stroke = 1.75,
  style,
  className,
}: {
  name: IconName;
  size?: number;
  stroke?: number;
  style?: CSSProperties;
  className?: string;
}) {
  const d = ICONS[name] || "";
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      style={{ display: "block", flexShrink: 0, ...style }}
      dangerouslySetInnerHTML={{ __html: d }}
    />
  );
}

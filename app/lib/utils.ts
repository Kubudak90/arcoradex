export function shortAddr(a?: string | null): string {
  if (!a) return "";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

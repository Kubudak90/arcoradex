import { Wordmark } from "@/components/brand/Wordmark";

const COLUMNS = [
  {
    h: "Protocol",
    links: [
      { label: "Swap", href: "/" },
      { label: "Liquidity", href: "/liquidity" },
      { label: "Pool", href: "/pool" },
    ],
  },
  {
    h: "Develop",
    links: [
      { label: "Docs", href: "https://github.com/Kubudak90/arcoradex/tree/main/docs" },
      { label: "SDK", href: "https://github.com/Kubudak90/arcoradex/tree/main/packages/sdk" },
      { label: "GitHub", href: "https://github.com/Kubudak90/arcoradex" },
      { label: "Audit", href: "#" },
    ],
  },
  {
    h: "Ecosystem",
    links: [
      { label: "ArcoraPay", href: "https://arcorapay.xyz" },
      { label: "Arc Network", href: "https://arc.network" },
      { label: "Treasury", href: "#" },
      { label: "Brand", href: "#" },
    ],
  },
  {
    h: "Network",
    links: [
      { label: "Arc Testnet", href: "https://testnet.arcscan.app" },
      { label: "Status", href: "#" },
      { label: "Bridge", href: "#" },
    ],
  },
];

export function Footer() {
  return (
    <footer className="border-t border-arc-ink-100 bg-surface mt-20">
      <div className="mx-auto max-w-[1280px] px-8 py-12 grid grid-cols-1 md:grid-cols-[2fr_1fr_1fr_1fr_1fr] gap-8">
        <div>
          <Wordmark size={28} />
          <p className="mt-4 text-arc-ink-500 text-[13px] max-w-[280px] leading-relaxed">
            Stableswap built on Arc Testnet. Part of the ArcoraPay ecosystem — settle in any stable, swap at oracle price.
          </p>
        </div>
        {COLUMNS.map((c) => (
          <div key={c.h}>
            <div className="t-label mb-3">{c.h}</div>
            <ul className="list-none p-0 m-0 flex flex-col gap-2">
              {c.links.map((l) => (
                <li key={l.label}>
                  <a
                    href={l.href}
                    target={l.href.startsWith("http") ? "_blank" : undefined}
                    rel={l.href.startsWith("http") ? "noreferrer" : undefined}
                    className="text-[13px] text-arc-ink-700 hover:text-arc-ink-900 transition-colors"
                  >
                    {l.label}
                  </a>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
      <div className="border-t border-arc-ink-100">
        <div
          className="mx-auto max-w-[1280px] px-8 py-5 flex justify-between items-center text-xs text-arc-ink-500"
          style={{ fontFamily: "var(--font-mono)" }}
        >
          <div>© 2026 ArcoraLabs · v1.0-testnet</div>
          <div className="flex gap-4 items-center">
            <span>
              Status: <span style={{ color: "var(--color-success)" }}>● Operational</span>
            </span>
            <a href="#" className="hover:text-arc-ink-900 transition-colors">Terms</a>
            <a href="#" className="hover:text-arc-ink-900 transition-colors">Privacy</a>
          </div>
        </div>
      </div>
    </footer>
  );
}

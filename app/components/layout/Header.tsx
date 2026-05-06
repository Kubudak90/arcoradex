import Link from "next/link";
import Image from "next/image";
import { ConnectButton } from "@/components/wallet/ConnectButton";

export function Header() {
  return (
    <header className="sticky top-0 z-30 border-b border-border bg-bg/80 backdrop-blur">
      <div className="mx-auto max-w-5xl px-6 py-4 flex items-center justify-between">
        <Link href="/" className="flex items-center gap-2">
          <Image
            src="/brand/arcora-dex-logo-mono.svg"
            alt="ArcoraDEX"
            width={156}
            height={42}
            className="hidden sm:block"
            priority
          />
          <Image
            src="/brand/arcora-dex-symbol-mono.svg"
            alt="ArcoraDEX"
            width={36}
            height={36}
            className="sm:hidden"
            priority
          />
        </Link>
        <nav className="flex items-center gap-6 text-sm text-fg-muted">
          <Link href="/" className="hover:text-fg transition">Swap</Link>
          <Link href="/liquidity" className="hover:text-fg transition">Liquidity</Link>
          <Link href="/pool" className="hover:text-fg transition">Pool</Link>
        </nav>
        <ConnectButton />
      </div>
    </header>
  );
}

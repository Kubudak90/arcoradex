import type { Metadata } from "next";
import { Providers } from "@/components/wallet/Providers";
import { Header } from "@/components/layout/Header";
import { Footer } from "@/components/layout/Footer";
import "./globals.css";

export const metadata: Metadata = {
  title: "ArcoraDEX — Oracle-priced multi-stable DEX",
  description:
    "Public-LP, oracle-priced multi-stablecoin DEX on Arc. Deposit any active stable, earn 90% of swap fees, withdraw single-token at oracle price.",
  metadataBase: new URL("https://swap.arcorapay.xyz"),
  openGraph: {
    title: "ArcoraDEX",
    description: "Oracle-priced multi-stablecoin DEX with public liquidity",
    url: "https://swap.arcorapay.xyz",
    siteName: "ArcoraDEX",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className="h-full">
      <body className="min-h-full flex flex-col bg-surface-page text-arc-ink-900">
        <Providers>
          <Header />
          <main className="flex-1 mx-auto w-full max-w-[1280px] px-8 py-8">{children}</main>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}

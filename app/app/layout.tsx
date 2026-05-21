import type { Metadata } from "next";
import { BotIdClient } from "botid/client";
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
      <head>
        {/* Vercel BotID signal collection — protects /api/faucet from automated abuse. */}
        <BotIdClient protect={[{ path: "/api/faucet", method: "POST" }]} />
        {/* Load fonts in <head> so Material Symbols ligatures resolve before first paint. */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&family=Roboto+Flex:opsz,wght@8..144,300..700&family=Roboto+Mono:wght@400;500&display=swap"
        />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@24,400,0,0&display=block"
        />
      </head>
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

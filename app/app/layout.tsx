import type { Metadata } from "next";
import { BotIdClient } from "botid/client";
import { Providers } from "@/components/wallet/Providers";
import { Header } from "@/components/layout/Header";
import { Footer } from "@/components/layout/Footer";
import { Background } from "@/components/layout/Background";
import { Toasts } from "@/components/layout/Toasts";
import { PageFade } from "@/components/layout/PageFade";
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
    <html lang="en" data-theme="dark" className="h-full">
      <head>
        {/* Vercel BotID signal collection — protects /api/faucet from automated abuse. */}
        <BotIdClient protect={[{ path: "/api/faucet", method: "POST" }]} />
        {/* Hanken Grotesk + IBM Plex Mono are loaded via the @import in
            globals.css; preconnect here so the CDN handshake starts early. */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
      </head>
      <body className="min-h-full bg-bg text-fg-1" style={{ position: "relative" }}>
        <Providers>
          <Background style="mesh" motion />
          <div style={{ position: "relative", zIndex: 1 }}>
            <Header />
            <main
              style={{
                padding: "44px 24px 0",
                margin: "0 auto",
                width: "100%",
                maxWidth: 1280,
                minHeight: "calc(100vh - 320px)",
              }}
            >
              <PageFade>{children}</PageFade>
            </main>
            <Footer />
          </div>
          <Toasts />
        </Providers>
      </body>
    </html>
  );
}

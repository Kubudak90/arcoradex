"use client";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-full font-medium transition-all disabled:pointer-events-none disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-arc-blue-400",
  {
    variants: {
      variant: {
        primary: "bg-arc-ink-900 text-white hover:bg-arc-ink-800 hover:-translate-y-px hover:shadow-md",
        gradient: "text-white",
        ghost: "bg-arc-ink-50 text-arc-ink-900 hover:bg-arc-ink-100",
        outline:
          "bg-transparent text-arc-ink-900 ring-1 ring-inset ring-arc-ink-200 hover:bg-arc-ink-25",
        danger: "bg-danger text-white hover:opacity-90",
      },
      size: {
        default: "h-11 px-5 text-sm",
        sm: "h-9 px-4 text-[13px]",
        lg: "h-13 px-7 text-[15px]",
        icon: "h-10 w-10 p-0",
      },
    },
    defaultVariants: { variant: "primary", size: "default" },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, style, ...props }, ref) => {
    const Comp = asChild ? Slot : "button";
    const gradientStyle =
      variant === "gradient"
        ? { background: "var(--grad-arcora)", boxShadow: "var(--shadow-glow)", ...style }
        : style;
    return (
      <Comp
        ref={ref}
        className={cn(buttonVariants({ variant, size, className }))}
        style={gradientStyle}
        {...props}
      />
    );
  },
);
Button.displayName = "Button";

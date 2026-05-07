"use client";
import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";
import { cn } from "@/lib/utils";

interface ModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title?: React.ReactNode;
  description?: React.ReactNode;
  className?: string;
  children: React.ReactNode;
}

export function Modal({ open, onOpenChange, title, description, className, children }: ModalProps) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay
          className="fixed inset-0 z-50 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0"
          style={{ background: "rgba(11,20,38,0.4)", backdropFilter: "blur(4px)" }}
        />
        <Dialog.Content
          className={cn(
            "fixed left-[50%] top-[50%] z-50 grid w-full max-w-md -translate-x-1/2 -translate-y-1/2 gap-4 bg-surface p-6 rounded-[28px] focus:outline-none data-[state=open]:animate-in data-[state=closed]:animate-out",
            className,
          )}
          style={{ boxShadow: "var(--shadow-lg)" }}
        >
          {title ? (
            <Dialog.Title className="t-title-l text-arc-ink-900 m-0">{title}</Dialog.Title>
          ) : (
            <Dialog.Title className="sr-only">Dialog</Dialog.Title>
          )}
          {description ? (
            <Dialog.Description className="t-body-s text-arc-ink-500 m-0">
              {description}
            </Dialog.Description>
          ) : null}
          <div>{children}</div>
          <Dialog.Close
            aria-label="Close"
            className="absolute top-4 right-4 inline-flex h-8 w-8 items-center justify-center rounded-full hover:bg-arc-ink-50 text-arc-ink-500"
          >
            <span className="ms" style={{ fontSize: 18 }}>
              close
            </span>
          </Dialog.Close>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

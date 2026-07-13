"use client";

import { CopilotKit, useCopilotMessagesContext } from "@copilotkit/react-core";
import { CopilotChat } from "@copilotkit/react-ui";
import "@copilotkit/react-ui/styles.css";
import { useEffect, useRef, useState } from "react";

// ── Client-side chat persistence (localStorage) ───────────────────────────────
// Multiple named threads, each with its own message history, surviving refresh.
// Nothing is stored server-side; this is per-browser.

type Thread = { id: string; title: string };

const THREADS_KEY = "pp_threads";
const ACTIVE_KEY = "pp_active_thread";
const msgsKey = (id: string) => `pp_msgs_${id}`;

const newThread = (): Thread => ({ id: crypto.randomUUID(), title: "New chat" });

export default function Home() {
  const [mounted, setMounted] = useState(false);
  const [threads, setThreads] = useState<Thread[]>([]);
  const [activeId, setActiveId] = useState("");

  // Load persisted threads once, on the client (avoids SSR/hydration issues).
  useEffect(() => {
    let t: Thread[] = [];
    try {
      t = JSON.parse(localStorage.getItem(THREADS_KEY) || "[]");
    } catch {
      t = [];
    }
    let a = localStorage.getItem(ACTIVE_KEY) || "";
    if (!Array.isArray(t) || t.length === 0) {
      const n = newThread();
      t = [n];
      a = n.id;
    }
    if (!t.some((x) => x.id === a)) a = t[0].id;
    setThreads(t);
    setActiveId(a);
    setMounted(true);
  }, []);

  useEffect(() => {
    if (mounted) localStorage.setItem(THREADS_KEY, JSON.stringify(threads));
  }, [threads, mounted]);
  useEffect(() => {
    if (mounted && activeId) localStorage.setItem(ACTIVE_KEY, activeId);
  }, [activeId, mounted]);

  const handleNew = () => {
    const n = newThread();
    setThreads((prev) => [n, ...prev]);
    setActiveId(n.id);
  };

  const handleDelete = (id: string) => {
    localStorage.removeItem(msgsKey(id));
    setThreads((prev) => {
      const next = prev.filter((t) => t.id !== id);
      if (next.length === 0) {
        const n = newThread();
        setActiveId(n.id);
        return [n];
      }
      if (id === activeId) setActiveId(next[0].id);
      return next;
    });
  };

  const setTitle = (id: string, title: string) =>
    setThreads((prev) => prev.map((t) => (t.id === id ? { ...t, title } : t)));

  if (!mounted) return null;

  return (
    <div style={{ display: "flex", height: "100dvh", fontFamily: "system-ui, sans-serif" }}>
      <aside
        style={{
          width: 260,
          flexShrink: 0,
          borderRight: "1px solid #e5e7eb",
          background: "#f9fafb",
          display: "flex",
          flexDirection: "column",
        }}
      >
        <div style={{ padding: 12, borderBottom: "1px solid #e5e7eb" }}>
          <button
            onClick={handleNew}
            style={{
              width: "100%",
              padding: "8px 12px",
              borderRadius: 8,
              border: "1px solid #d1d5db",
              background: "#fff",
              cursor: "pointer",
              fontWeight: 600,
            }}
          >
            + New chat
          </button>
        </div>
        <ul style={{ listStyle: "none", margin: 0, padding: 8, overflowY: "auto", flex: 1 }}>
          {threads.map((t) => {
            const active = t.id === activeId;
            return (
              <li
                key={t.id}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 4,
                  borderRadius: 8,
                  background: active ? "#e0e7ff" : "transparent",
                }}
              >
                <button
                  onClick={() => setActiveId(t.id)}
                  title={t.title}
                  style={{
                    flex: 1,
                    minWidth: 0,
                    textAlign: "left",
                    padding: "8px 10px",
                    border: "none",
                    background: "transparent",
                    cursor: "pointer",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                    fontWeight: active ? 600 : 400,
                  }}
                >
                  {t.title || "New chat"}
                </button>
                <button
                  onClick={() => handleDelete(t.id)}
                  aria-label="Delete chat"
                  style={{
                    border: "none",
                    background: "transparent",
                    cursor: "pointer",
                    color: "#9ca3af",
                    fontSize: 18,
                    lineHeight: 1,
                    padding: "0 8px",
                  }}
                >
                  ×
                </button>
              </li>
            );
          })}
        </ul>
      </aside>

      <main style={{ flex: 1, minWidth: 0 }}>
        {/* key={activeId} remounts CopilotKit per thread → clean isolation. */}
        <CopilotKit key={activeId} runtimeUrl="/api/copilotkit" agent="pipeline_pulse" threadId={activeId}>
          <Chat threadId={activeId} onTitle={setTitle} />
        </CopilotKit>
      </main>
    </div>
  );
}

function Chat({ threadId, onTitle }: { threadId: string; onTitle: (id: string, title: string) => void }) {
  const { messages, setMessages } = useCopilotMessagesContext();
  const loaded = useRef(false);

  // Restore this thread's messages on mount.
  useEffect(() => {
    try {
      const saved = localStorage.getItem(msgsKey(threadId));
      if (saved) setMessages(JSON.parse(saved));
    } catch {
      /* ignore corrupt state */
    }
    loaded.current = true;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Persist on change + derive the thread title from the first user message.
  useEffect(() => {
    if (!loaded.current) return;
    try {
      localStorage.setItem(msgsKey(threadId), JSON.stringify(messages));
    } catch {
      /* quota / serialization — ignore */
    }
    const firstUser = (messages as any[]).find((m) => m?.role === "user");
    const text = firstUser?.content;
    if (typeof text === "string" && text.trim()) {
      onTitle(threadId, text.trim().slice(0, 40));
    }
  }, [messages, threadId, onTitle]);

  return (
    <div style={{ height: "100%", display: "flex", flexDirection: "column" }}>
      <CopilotChat
        className="h-full"
        labels={{
          title: "Pipeline Pulse Agent UI",
          initial: "Ask about ServiceNow Incident Tickets (e.g. \"INC0042047\").",
        }}
      />
    </div>
  );
}

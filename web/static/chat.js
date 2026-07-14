/**
 * AI-RAGJus Web GUI - chat frontend logic.
 *
 * The backend (/api/chat) is a real text/event-stream (SSE) response, but
 * EventSource cannot send a POST body, so we drive it with fetch() + a
 * ReadableStream reader and parse the "data: {...}\n\n" frames ourselves.
 * This gives the same real-time token-by-token UX as EventSource without
 * needing a GET-with-querystring workaround.
 */
(function () {
    "use strict";

    const messagesEl = document.getElementById("messages");
    const formEl = document.getElementById("chat-form");
    const inputEl = document.getElementById("chat-input");
    const sendBtn = document.getElementById("send-btn");
    const statusDot = document.getElementById("status-dot");
    const sessionListEl = document.getElementById("session-list");
    const newChatBtn = document.getElementById("new-chat-btn");

    let currentSessionId = null;
    let sending = false;

    function setStatus(state) {
        statusDot.classList.remove("busy", "error");
        if (state === "busy") statusDot.classList.add("busy");
        if (state === "error") statusDot.classList.add("error");
    }

    function formatTime(date) {
        return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    }

    function scrollToBottom() {
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    function addMessage(role, content, opts) {
        opts = opts || {};
        const wrap = document.createElement("div");
        wrap.className = "message " + role;

        const roleLine = document.createElement("div");
        roleLine.className = "message-role";

        const roleLabel = document.createElement("span");
        roleLabel.textContent = role === "user" ? "Advogado" : role === "error" ? "Erro" : "AI-RAGJus";

        const timeLabel = document.createElement("span");
        timeLabel.className = "message-timestamp";
        timeLabel.textContent = formatTime(new Date());

        roleLine.appendChild(roleLabel);
        roleLine.appendChild(timeLabel);

        const contentEl = document.createElement("div");
        contentEl.className = "message-content";
        contentEl.textContent = content || "";
        if (opts.streaming) {
            contentEl.classList.add("cursor-blink");
        }

        wrap.appendChild(roleLine);
        wrap.appendChild(contentEl);

        if (opts.sources && opts.sources.length) {
            const sourcesEl = document.createElement("div");
            sourcesEl.className = "sources";
            opts.sources.forEach(function (src) {
                const pill = document.createElement("span");
                pill.className = "source-pill";
                const name = (src.caminho || "").split("/").pop() || src.caminho || "fonte";
                const score = typeof src.score === "number" ? " (" + src.score.toFixed(2) + ")" : "";
                pill.textContent = name + score;
                pill.title = src.caminho || "";
                sourcesEl.appendChild(pill);
            });
            wrap.appendChild(sourcesEl);
        }

        messagesEl.appendChild(wrap);
        scrollToBottom();
        return contentEl;
    }

    function clearMessages() {
        messagesEl.innerHTML = "";
    }

    /**
     * Reads a fetch() Response body as a stream of SSE "data: {...}\n\n"
     * frames and invokes onEvent(parsedJson) for each one. Shared by
     * streamChat() and syncDocuments() so both speak the same wire format.
     */
    async function consumeSSE(response, onEvent) {
        const reader = response.body.getReader();
        const decoder = new TextDecoder("utf-8");
        let buffer = "";

        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;

            buffer += decoder.decode(value, { stream: true });

            let frameEnd;
            while ((frameEnd = buffer.indexOf("\n\n")) !== -1) {
                const frame = buffer.slice(0, frameEnd);
                buffer = buffer.slice(frameEnd + 2);

                const dataLines = frame
                    .split("\n")
                    .filter(function (l) { return l.startsWith("data:"); })
                    .map(function (l) { return l.slice(5).trim(); });

                if (!dataLines.length) continue;

                let event;
                try {
                    event = JSON.parse(dataLines.join(""));
                } catch (e) {
                    continue;
                }

                onEvent(event);
            }
        }
    }

    function markActiveSession(sessionId) {
        Array.prototype.forEach.call(sessionListEl.querySelectorAll(".session-item"), function (el) {
            el.classList.toggle("active", String(sessionId) === el.dataset.sessionId);
        });
    }

    function refreshSessionList() {
        fetch("/api/sessions")
            .then(function (r) { return r.json(); })
            .then(function (sessions) {
                sessionListEl.innerHTML = "";
                if (!sessions.length) {
                    const p = document.createElement("p");
                    p.className = "session-empty";
                    p.textContent = "Nenhuma conversa ainda.";
                    sessionListEl.appendChild(p);
                    return;
                }
                sessions.forEach(function (s) {
                    const btn = document.createElement("button");
                    btn.type = "button";
                    btn.className = "session-item";
                    btn.dataset.sessionId = s.id;
                    btn.textContent = s.title || "Nova conversa";
                    btn.addEventListener("click", function () { loadSession(s.id); });
                    sessionListEl.appendChild(btn);
                });
                markActiveSession(currentSessionId);
            })
            .catch(function () { /* sidebar refresh is best-effort */ });
    }

    function loadSession(sessionId) {
        fetch("/api/sessions/" + sessionId)
            .then(function (r) {
                if (!r.ok) throw new Error("Sessão não encontrada.");
                return r.json();
            })
            .then(function (data) {
                currentSessionId = sessionId;
                clearMessages();
                data.messages.forEach(function (m) {
                    addMessage(m.role, m.content, { sources: m.sources });
                });
                markActiveSession(sessionId);
            })
            .catch(function (err) {
                addMessage("error", "Falha ao carregar conversa: " + err.message);
            });
    }

    newChatBtn.addEventListener("click", function () {
        currentSessionId = null;
        clearMessages();
        addMessage("assistant",
            "Nova conversa iniciada. Faça uma pergunta sobre o seu acervo de documentos.");
        markActiveSession(null);
        inputEl.focus();
    });

    // Auto-grow the textarea
    inputEl.addEventListener("input", function () {
        inputEl.style.height = "auto";
        inputEl.style.height = Math.min(inputEl.scrollHeight, 160) + "px";
    });

    inputEl.addEventListener("keydown", function (ev) {
        if (ev.key === "Enter" && !ev.shiftKey) {
            ev.preventDefault();
            formEl.requestSubmit();
        }
    });

    async function streamChat(query) {
        setStatus("busy");
        sending = true;
        sendBtn.disabled = true;

        const assistantContentEl = addMessage("assistant", "", { streaming: true });
        let accumulated = "";
        let sources = [];
        let sawError = false;

        try {
            const response = await fetch("/api/chat", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ query: query, session_id: currentSessionId }),
            });

            if (!response.ok || !response.body) {
                const errBody = await response.json().catch(function () { return {}; });
                throw new Error(errBody.error || ("Erro HTTP " + response.status));
            }

            await consumeSSE(response, function (event) {
                if (event.type === "session" && event.session_id) {
                    currentSessionId = event.session_id;
                } else if (event.type === "token") {
                    accumulated += event.content || "";
                    assistantContentEl.textContent = accumulated;
                    scrollToBottom();
                } else if (event.type === "sources") {
                    sources = event.content || [];
                } else if (event.type === "error") {
                    sawError = true;
                    accumulated += (accumulated ? "\n" : "") + "[Erro] " + event.content;
                    assistantContentEl.textContent = accumulated;
                    assistantContentEl.closest(".message").classList.add("error");
                }
                // "done" is a no-op; the loop ends when the stream closes.
            });
        } catch (err) {
            sawError = true;
            accumulated += (accumulated ? "\n" : "") + "[Erro de conexão] " + err.message;
            assistantContentEl.textContent = accumulated;
            assistantContentEl.closest(".message").classList.add("error");
        }

        assistantContentEl.classList.remove("cursor-blink");
        if (sources.length) {
            const sourcesEl = document.createElement("div");
            sourcesEl.className = "sources";
            sources.forEach(function (src) {
                const pill = document.createElement("span");
                pill.className = "source-pill";
                const name = (src.caminho || "").split("/").pop() || src.caminho || "fonte";
                const score = typeof src.score === "number" ? " (" + src.score.toFixed(2) + ")" : "";
                pill.textContent = name + score;
                pill.title = src.caminho || "";
                sourcesEl.appendChild(pill);
            });
            assistantContentEl.closest(".message").appendChild(sourcesEl);
        }

        setStatus(sawError ? "error" : "idle");
        sending = false;
        sendBtn.disabled = false;
        refreshSessionList();
        scrollToBottom();
    }

    formEl.addEventListener("submit", function (ev) {
        ev.preventDefault();
        if (sending) return;

        const query = inputEl.value.trim();
        if (!query) return;

        addMessage("user", query);
        inputEl.value = "";
        inputEl.style.height = "auto";

        streamChat(query);
    });

    // Wire up server-rendered session items on first load
    Array.prototype.forEach.call(document.querySelectorAll(".session-item"), function (el) {
        el.addEventListener("click", function () {
            loadSession(el.dataset.sessionId);
        });
    });

    // --- Document re-sync -------------------------------------------------
    // Runs independently of the chat flow: it does not touch `sending` /
    // sendBtn, so questions can still be asked while a sync is in progress.
    const syncBtn = document.getElementById("sync-btn");
    const syncMessageEl = document.getElementById("sync-message");
    let syncing = false;

    function setSyncMessage(text, kind) {
        syncMessageEl.textContent = text || "";
        syncMessageEl.classList.remove("error", "success");
        if (kind) syncMessageEl.classList.add(kind);
    }

    async function syncDocuments() {
        if (syncing) return;
        syncing = true;
        syncBtn.disabled = true;
        syncBtn.classList.add("syncing");
        setSyncMessage("Sincronizando documentos...");

        let lastProgress = "";
        let sawError = false;

        try {
            const response = await fetch("/api/sync", { method: "POST" });

            if (response.status === 409) {
                const body = await response.json().catch(function () { return {}; });
                setSyncMessage(body.message || "Sincronização já em andamento.", "error");
                return;
            }

            if (!response.ok || !response.body) {
                const body = await response.json().catch(function () { return {}; });
                throw new Error(body.message || ("Erro HTTP " + response.status));
            }

            await consumeSSE(response, function (event) {
                if (event.type === "progress") {
                    lastProgress = event.content || "";
                    setSyncMessage(lastProgress);
                } else if (event.type === "error") {
                    sawError = true;
                    setSyncMessage(event.content || "Erro durante a sincronização.", "error");
                } else if (event.type === "complete") {
                    const chunks = typeof event.chunks_count === "number" ? event.chunks_count : "?";
                    const files = typeof event.files_count === "number" ? event.files_count : "?";
                    setSyncMessage(
                        "Sincronização concluída: " + files + " arquivo(s), " + chunks + " bloco(s) indexados.",
                        sawError ? "error" : "success"
                    );
                }
                // "done" is a no-op; the loop ends when the stream closes.
            });
        } catch (err) {
            setSyncMessage("Falha na sincronização: " + err.message, "error");
        } finally {
            syncing = false;
            syncBtn.disabled = false;
            syncBtn.classList.remove("syncing");
        }
    }

    syncBtn.addEventListener("click", syncDocuments);

    setStatus("idle");
})();

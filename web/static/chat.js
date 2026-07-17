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
    const sidebarToggleBtn = document.getElementById("sidebar-toggle");
    const sidebarEl = document.getElementById("sidebar");
    const sidebarOverlayEl = document.getElementById("sidebar-overlay");

    let currentSessionId = null;
    let sending = false;

    // Multi-doc scope selector state. `pendingScope` holds the selection made
    // before a session exists yet (new chat, no message sent); once a session
    // is created the scope lives server-side (session_doc_scope table) and is
    // read/written via /api/sessions/<id>/scope instead.
    let pendingScope = [];

    function setStatus(state) {
        statusDot.classList.remove("busy", "error");
        if (state === "busy") statusDot.classList.add("busy");
        if (state === "error") statusDot.classList.add("error");
    }

    // --- Mobile sidebar toggle ---------------------------------------------
    // The sidebar is always visible on desktop (CSS media query keeps the
    // toggle button hidden there); on narrow screens it starts off-canvas and
    // slides in as an overlay so the chat pane stays full-width underneath.
    function openSidebar() {
        if (!sidebarEl) return;
        sidebarEl.classList.add("sidebar-open");
        if (sidebarOverlayEl) sidebarOverlayEl.classList.add("visible");
        if (sidebarToggleBtn) sidebarToggleBtn.setAttribute("aria-expanded", "true");
    }

    function closeSidebar() {
        if (!sidebarEl) return;
        sidebarEl.classList.remove("sidebar-open");
        if (sidebarOverlayEl) sidebarOverlayEl.classList.remove("visible");
        if (sidebarToggleBtn) sidebarToggleBtn.setAttribute("aria-expanded", "false");
    }

    if (sidebarToggleBtn) {
        sidebarToggleBtn.addEventListener("click", function () {
            if (sidebarEl.classList.contains("sidebar-open")) closeSidebar();
            else openSidebar();
        });
    }

    if (sidebarOverlayEl) {
        sidebarOverlayEl.addEventListener("click", closeSidebar);
    }

    document.addEventListener("keydown", function (ev) {
        if (ev.key === "Escape") closeSidebar();
    });

    function formatTime(date) {
        return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    }

    function scrollToBottom() {
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    // --- Markdown rendering ---------------------------------------------
    // Small, dependency-free markdown-to-HTML converter. No CDN / npm
    // package is used on purpose: the app must keep working 100% offline
    // (see CLAUDE.md), so a vendored or network-fetched library is avoided
    // in favor of a compact hand-rolled renderer covering the common
    // subset (headers, bold/italic, inline code, code blocks, lists,
    // blockquotes, links). Input is HTML-escaped first so nothing in a
    // model response (or a source document it quotes) can inject markup.
    function escapeHtml(str) {
        return String(str)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
    }

    function renderInline(text) {
        // text is already HTML-escaped.
        text = text.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, function (m, label, url) {
            return '<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + label + "</a>";
        });
        text = text.replace(/`([^`]+)`/g, "<code>$1</code>");
        text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
        text = text.replace(/__([^_]+)__/g, "<strong>$1</strong>");
        text = text.replace(/\*([^*]+)\*/g, "<em>$1</em>");
        text = text.replace(/(^|[^\w])_([^_]+)_(?=[^\w]|$)/g, "$1<em>$2</em>");
        return text;
    }

    function renderMarkdown(raw) {
        if (!raw) return "";
        const lines = escapeHtml(raw).split("\n");

        let html = "";
        let inCodeBlock = false;
        let codeBuffer = [];
        let listType = null; // "ul" | "ol"
        let paragraphBuffer = [];

        function flushParagraph() {
            if (paragraphBuffer.length) {
                // Join with <br> (not a space) so a single "\n" in the model's
                // response still produces a visible line break, matching the
                // literal newlines the model actually emits rather than
                // collapsing them the way strict markdown reflow would.
                html += "<p>" + renderInline(paragraphBuffer.join("<br>")) + "</p>";
                paragraphBuffer = [];
            }
        }
        function closeList() {
            if (listType) {
                html += "</" + listType + ">";
                listType = null;
            }
        }

        lines.forEach(function (line) {
            if (/^```/.test(line)) {
                if (inCodeBlock) {
                    html += "<pre><code>" + codeBuffer.join("\n") + "</code></pre>";
                    codeBuffer = [];
                    inCodeBlock = false;
                } else {
                    flushParagraph();
                    closeList();
                    inCodeBlock = true;
                }
                return;
            }
            if (inCodeBlock) {
                codeBuffer.push(line);
                return;
            }

            const headerMatch = line.match(/^(#{1,6})\s+(.*)$/);
            const ulMatch = line.match(/^\s*[-*+]\s+(.*)$/);
            const olMatch = line.match(/^\s*\d+\.\s+(.*)$/);
            const bqMatch = line.match(/^>\s?(.*)$/);

            if (headerMatch) {
                flushParagraph();
                closeList();
                const level = headerMatch[1].length;
                html += "<h" + level + ">" + renderInline(headerMatch[2]) + "</h" + level + ">";
            } else if (ulMatch) {
                flushParagraph();
                if (listType !== "ul") { closeList(); html += "<ul>"; listType = "ul"; }
                html += "<li>" + renderInline(ulMatch[1]) + "</li>";
            } else if (olMatch) {
                flushParagraph();
                if (listType !== "ol") { closeList(); html += "<ol>"; listType = "ol"; }
                html += "<li>" + renderInline(olMatch[1]) + "</li>";
            } else if (bqMatch && line.trim().length) {
                flushParagraph();
                closeList();
                html += "<blockquote>" + renderInline(bqMatch[1]) + "</blockquote>";
            } else if (line.trim() === "") {
                flushParagraph();
                closeList();
            } else {
                paragraphBuffer.push(line.trim());
            }
        });

        // Unterminated fence (e.g. mid-stream): flush what we have so far
        // rather than losing it; a later re-render (with the closing ```
        // token) will clean it up.
        if (inCodeBlock) {
            html += "<pre><code>" + codeBuffer.join("\n") + "</code></pre>";
        }
        flushParagraph();
        closeList();

        return html;
    }

    // --- <think> block rendering -------------------------------------------
    // Reasoning models (deepseek-r1, qwq, ...) wrap their chain-of-thought in
    // <think>...</think> before the final answer. Rendered as a collapsible,
    // muted block so it doesn't compete visually with the actual answer, but
    // stays available for legal-review transparency. Streaming-safe: a block
    // whose closing tag hasn't arrived yet is shown open and marked "em
    // andamento" rather than waiting for it.
    function renderAssistantContent(raw) {
        if (!raw) return "";

        const OPEN_TAG = "<think>";
        const CLOSE_TAG = "</think>";

        let html = "";
        let rest = raw;

        for (;;) {
            const openIdx = rest.indexOf(OPEN_TAG);
            if (openIdx === -1) break;

            html += renderMarkdown(rest.slice(0, openIdx));
            const afterOpen = rest.slice(openIdx + OPEN_TAG.length);
            const closeIdx = afterOpen.indexOf(CLOSE_TAG);

            let thinkText, inProgress;
            if (closeIdx === -1) {
                thinkText = afterOpen;
                rest = "";
                inProgress = true;
            } else {
                thinkText = afterOpen.slice(0, closeIdx);
                rest = afterOpen.slice(closeIdx + CLOSE_TAG.length);
                inProgress = false;
            }

            html += "<details class=\"think-block\"" + (inProgress ? " open" : "") + ">" +
                "<summary>💭 " + (inProgress ? "Pensando…" : "Raciocínio") + "</summary>" +
                "<div class=\"think-content\">" + escapeHtml(thinkText).replace(/\n/g, "<br>") + "</div>" +
                "</details>";

            if (inProgress) break;
        }

        html += renderMarkdown(rest);
        return html;
    }

    // --- Copy-to-clipboard -------------------------------------------------
    function fallbackCopy(text) {
        const ta = document.createElement("textarea");
        ta.value = text;
        ta.style.position = "fixed";
        ta.style.top = "-1000px";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.focus();
        ta.select();
        let ok = false;
        try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
        document.body.removeChild(ta);
        return ok;
    }

    function createCopyButton(contentEl, label) {
        label = label || "resposta";
        const idleTitle = "Copiar " + label;

        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "copy-btn";
        btn.textContent = "📋"; // 📋
        btn.title = idleTitle;
        btn.setAttribute("aria-label", idleTitle);

        function showFeedback(ok) {
            btn.textContent = ok ? "✅" : "❌"; // ✅ / ❌
            btn.title = ok ? "Copiado!" : "Falhou ao copiar";
            btn.setAttribute("aria-label", btn.title);
            btn.classList.toggle("copied", ok);
            setTimeout(function () {
                btn.textContent = "📋"; // 📋
                btn.title = idleTitle;
                btn.setAttribute("aria-label", idleTitle);
                btn.classList.remove("copied");
            }, 1500);
        }

        btn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            const text = contentEl.dataset.raw || contentEl.textContent || "";
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text)
                    .then(function () { showFeedback(true); })
                    .catch(function () { showFeedback(fallbackCopy(text)); });
            } else {
                showFeedback(fallbackCopy(text));
            }
        });

        return btn;
    }

    function addMessage(role, content, opts) {
        opts = opts || {};
        const wrap = document.createElement("div");
        wrap.className = "message " + role;

        const roleLine = document.createElement("div");
        roleLine.className = "message-role";

        const roleLabel = document.createElement("span");
        roleLabel.textContent = role === "user" ? "Advogado" : role === "error" ? "Erro" : "AI-RAGJus";

        const rightGroup = document.createElement("span");
        rightGroup.className = "message-role-right";

        const timeLabel = document.createElement("span");
        timeLabel.className = "message-timestamp";
        timeLabel.textContent = formatTime(new Date());
        rightGroup.appendChild(timeLabel);

        roleLine.appendChild(roleLabel);
        roleLine.appendChild(rightGroup);

        const contentEl = document.createElement("div");
        contentEl.className = "message-content";
        contentEl.dataset.raw = content || "";
        if (role === "assistant") {
            contentEl.classList.add("markdown-content");
            contentEl.innerHTML = renderAssistantContent(content || "");
            rightGroup.appendChild(createCopyButton(contentEl, "resposta"));
        } else {
            contentEl.textContent = content || "";
            if (role === "user") {
                rightGroup.appendChild(createCopyButton(contentEl, "pergunta"));
            }
        }
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

    const SESSIONS_PAGE_SIZE = 30;
    let sessionsOffset = 0;
    let sessionsHasMore = true;
    let sessionsLoading = false;
    let sessionsObserver = null;

    function markActiveSession(sessionId) {
        Array.prototype.forEach.call(sessionListEl.querySelectorAll(".session-item"), function (el) {
            el.classList.toggle("active", String(sessionId) === el.dataset.sessionId);
        });
    }

    function buildSessionItem(s) {
        const item = document.createElement("div");
        item.className = "session-item";
        item.dataset.sessionId = s.id;

        const title = document.createElement("span");
        title.className = "session-title";
        title.textContent = s.title || "Nova conversa";
        title.addEventListener("click", function () { loadSession(s.id); });

        const menuBtn = document.createElement("button");
        menuBtn.type = "button";
        menuBtn.className = "session-menu-btn";
        menuBtn.textContent = "⋮"; // vertical ellipsis
        menuBtn.title = "Opções da conversa";
        menuBtn.setAttribute("aria-label", "Opções da conversa");
        menuBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            openSessionMenu(item, s);
        });

        item.appendChild(title);
        item.appendChild(menuBtn);
        return item;
    }

    function appendSessionSentinel() {
        removeSessionSentinel();
        const sentinel = document.createElement("div");
        sentinel.id = "session-sentinel";
        sentinel.className = "session-sentinel";
        sessionListEl.appendChild(sentinel);

        if (!sessionsObserver) {
            sessionsObserver = new IntersectionObserver(function (entries) {
                entries.forEach(function (entry) {
                    if (entry.isIntersecting) loadSessionsPage(false);
                });
            }, { root: sessionListEl });
        }
        sessionsObserver.observe(sentinel);
    }

    function removeSessionSentinel() {
        const existing = document.getElementById("session-sentinel");
        if (existing) {
            if (sessionsObserver) sessionsObserver.unobserve(existing);
            existing.remove();
        }
    }

    function loadSessionsPage(reset) {
        if (sessionsLoading) return;
        if (reset) {
            sessionsOffset = 0;
            sessionsHasMore = true;
        }
        if (!sessionsHasMore) return;

        sessionsLoading = true;
        fetch("/api/sessions?limit=" + SESSIONS_PAGE_SIZE + "&offset=" + sessionsOffset)
            .then(function (r) { return r.json(); })
            .then(function (data) {
                const sessions = data.sessions || [];
                sessionsHasMore = !!data.has_more;

                if (reset) sessionListEl.innerHTML = "";
                removeSessionSentinel();

                if (reset && !sessions.length) {
                    const p = document.createElement("p");
                    p.className = "session-empty";
                    p.textContent = "Nenhuma conversa ainda.";
                    sessionListEl.appendChild(p);
                    sessionsLoading = false;
                    return;
                }

                sessions.forEach(function (s) {
                    sessionListEl.appendChild(buildSessionItem(s));
                });
                sessionsOffset += sessions.length;

                if (sessionsHasMore) appendSessionSentinel();
                markActiveSession(currentSessionId);
                sessionsLoading = false;
            })
            .catch(function () {
                sessionsLoading = false; /* sidebar refresh is best-effort */
            });
    }

    function refreshSessionList() {
        loadSessionsPage(true);
    }

    // --- Session context menu (3-dots: rename / delete) --------------------
    let openMenuEl = null;

    function closeSessionMenu() {
        if (openMenuEl) {
            openMenuEl.remove();
            openMenuEl = null;
        }
        document.removeEventListener("click", handleOutsideMenuClick);
        document.removeEventListener("keydown", handleMenuEscape);
    }

    function handleOutsideMenuClick(ev) {
        if (openMenuEl && !openMenuEl.contains(ev.target)) closeSessionMenu();
    }

    function handleMenuEscape(ev) {
        if (ev.key === "Escape") closeSessionMenu();
    }

    function startRename(item, session) {
        closeSessionMenu();
        const titleEl = item.querySelector(".session-title");
        const original = titleEl.textContent;

        const input = document.createElement("input");
        input.type = "text";
        input.className = "session-title-input";
        input.value = original;
        input.maxLength = 120;

        titleEl.replaceWith(input);
        input.focus();
        input.select();

        let committed = false;

        function commit() {
            if (committed) return;
            committed = true;
            const newTitle = input.value.trim();
            if (!newTitle || newTitle === original) {
                input.replaceWith(titleEl);
                return;
            }
            fetch("/api/sessions/" + session.id, {
                method: "PATCH",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ title: newTitle }),
            })
                .then(function (r) { return r.json(); })
                .then(function (data) {
                    titleEl.textContent = data.title || newTitle;
                    input.replaceWith(titleEl);
                })
                .catch(function () {
                    titleEl.textContent = original;
                    input.replaceWith(titleEl);
                });
        }

        function cancel() {
            if (committed) return;
            committed = true;
            input.replaceWith(titleEl);
        }

        input.addEventListener("blur", commit);
        input.addEventListener("keydown", function (ev) {
            if (ev.key === "Enter") { ev.preventDefault(); commit(); }
            else if (ev.key === "Escape") { ev.preventDefault(); cancel(); }
        });
    }

    function confirmDelete(item, session) {
        closeSessionMenu();

        const confirmBar = document.createElement("div");
        confirmBar.className = "session-confirm-delete";

        const label = document.createElement("span");
        label.textContent = "Excluir?";

        const yesBtn = document.createElement("button");
        yesBtn.type = "button";
        yesBtn.textContent = "Sim";
        yesBtn.className = "confirm-yes";

        const noBtn = document.createElement("button");
        noBtn.type = "button";
        noBtn.textContent = "Cancelar";
        noBtn.className = "confirm-no";

        confirmBar.appendChild(label);
        confirmBar.appendChild(yesBtn);
        confirmBar.appendChild(noBtn);

        item.appendChild(confirmBar);

        noBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            confirmBar.remove();
        });

        yesBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            fetch("/api/sessions/" + session.id, { method: "DELETE" })
                .then(function () {
                    item.remove();
                    if (String(currentSessionId) === String(session.id)) {
                        currentSessionId = null;
                        clearMessages();
                        addMessage("assistant",
                            "Nova conversa iniciada. Faça uma pergunta sobre o seu acervo de documentos.");
                        markActiveSession(null);
                    }
                })
                .catch(function (err) {
                    confirmBar.remove();
                    console.error("Falha ao excluir conversa:", err);
                });
        });
    }

    function openSessionMenu(item, session) {
        closeSessionMenu();

        const menu = document.createElement("div");
        menu.className = "session-menu";

        const renameBtn = document.createElement("button");
        renameBtn.type = "button";
        renameBtn.textContent = "Renomear";
        renameBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            startRename(item, session);
        });

        const deleteBtn = document.createElement("button");
        deleteBtn.type = "button";
        deleteBtn.textContent = "Excluir";
        deleteBtn.className = "danger";
        deleteBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            confirmDelete(item, session);
        });

        menu.appendChild(renameBtn);
        menu.appendChild(deleteBtn);
        item.appendChild(menu);
        openMenuEl = menu;

        setTimeout(function () {
            document.addEventListener("click", handleOutsideMenuClick);
            document.addEventListener("keydown", handleMenuEscape);
        }, 0);
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
                loadSessionScope(sessionId);
                loadAttachmentsBar(sessionId);
                updateContextUsage({});
                closeSidebar();
            })
            .catch(function (err) {
                addMessage("error", "Falha ao carregar conversa: " + err.message);
            });
    }

    newChatBtn.addEventListener("click", function () {
        closeSidebar();
        currentSessionId = null;
        pendingScope = [];
        clearMessages();
        addMessage("assistant",
            "Nova conversa iniciada. Faça uma pergunta sobre o seu acervo de documentos.");
        markActiveSession(null);
        renderAttachmentsBar([]);
        Array.prototype.forEach.call(document.querySelectorAll(".doc-checkbox"), function (el) {
            el.checked = false;
        });
        updateScopePills([]);
        if (contextMonitorEl) {
            contextMonitorEl.className = "context-monitor";
            contextBarEl.style.width = "0%";
            contextTextEl.textContent = "…";
            contextMonitorEl.title = "";
        }
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
            const chatPayload = { query: query, session_id: currentSessionId };
            if (!currentSessionId && pendingScope.length > 0) {
                chatPayload.selected_docs = pendingScope;
            }

            const response = await fetch("/api/chat", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify(chatPayload),
            });

            if (!response.ok || !response.body) {
                const errBody = await response.json().catch(function () { return {}; });
                throw new Error(errBody.error || ("Erro HTTP " + response.status));
            }

            await consumeSSE(response, function (event) {
                if (event.type === "session" && event.session_id) {
                    currentSessionId = event.session_id;
                    // Scope was persisted server-side from `selected_docs` above
                    // (or is empty); the pending buffer is no longer needed.
                    pendingScope = [];
                    updateContextUsage({ query: query.length });
                } else if (event.type === "token") {
                    accumulated += event.content || "";
                    assistantContentEl.dataset.raw = accumulated;
                    assistantContentEl.innerHTML = renderAssistantContent(accumulated);
                    scrollToBottom();
                } else if (event.type === "sources") {
                    sources = event.content || [];
                    // Rough retrieved-docs char estimate (CHUNK_SIZE default ~1000/chunk).
                    updateContextUsage({ query: query.length, retrieved_docs: sources.length * 1000 });
                } else if (event.type === "stats") {
                    updateContextUsageExact(event.prompt_eval_count);
                } else if (event.type === "compact") {
                    // Backlog item 8: server auto-compacted this session's
                    // memory context after crossing the configured threshold.
                    showToast(
                        "🗜️ Contexto compactado automaticamente (turno " + event.turn + ").",
                        "success",
                        { duration: 6000 }
                    );
                    refreshMemoryPanel();
                    updateContextUsage({ query: query.length });
                } else if (event.type === "error") {
                    sawError = true;
                    accumulated += (accumulated ? "\n" : "") + "[Erro] " + event.content;
                    assistantContentEl.dataset.raw = accumulated;
                    assistantContentEl.innerHTML = renderAssistantContent(accumulated);
                    assistantContentEl.closest(".message").classList.add("error");
                }
                // "done" is a no-op; the loop ends when the stream closes.
            });
        } catch (err) {
            sawError = true;
            accumulated += (accumulated ? "\n" : "") + "[Erro de conexão] " + err.message;
            assistantContentEl.dataset.raw = accumulated;
            assistantContentEl.innerHTML = renderAssistantContent(accumulated);
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

    // --- File attachments (session-scoped RAG context, backlog item 9) -----
    // Drag-drop or the paperclip button send a file to
    // POST /api/sessions/<id>/attach-file, which extracts/chunks/embeds it
    // (reusing the CLI's src/ingest.sh + src/ai.sh functions) and stores the
    // result in the session_embeddings table - scoped to THIS conversation
    // only. Never touches the global vector store; closing/deleting the
    // session discards it. Injected ahead of global-store results on the
    // next question (see src/rag_query.sh + src/vector.sh::buscar_trechos_sessao).
    const attachBtn = document.getElementById("attach-btn");
    const attachFileInput = document.getElementById("attach-file-input");
    const dropOverlayEl = document.getElementById("drop-overlay");
    const attachmentsBarEl = document.getElementById("attachments-bar");
    const toastContainerEl = document.getElementById("toast-container");

    function formatBytes(bytes) {
        bytes = bytes || 0;
        if (bytes < 1024) return bytes + "B";
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + "KB";
        return (bytes / (1024 * 1024)).toFixed(1) + "MB";
    }

    function showToast(message, kind, opts) {
        opts = opts || {};
        const toast = document.createElement("div");
        toast.className = "toast" + (kind ? " toast-" + kind : "");

        const textEl = document.createElement("div");
        textEl.className = "toast-text";
        textEl.textContent = message;
        toast.appendChild(textEl);

        if (opts.progress) {
            const track = document.createElement("div");
            track.className = "toast-progress-track";
            const bar = document.createElement("div");
            bar.className = "toast-progress-bar";
            track.appendChild(bar);
            toast.appendChild(track);
            toast._bar = bar;
        }

        toastContainerEl.appendChild(toast);

        if (!opts.sticky) {
            dismissToast(toast, opts.duration || 4000);
        }
        return toast;
    }

    function dismissToast(toast, delay) {
        setTimeout(function () {
            toast.classList.add("toast-out");
            setTimeout(function () { toast.remove(); }, 250);
        }, delay);
    }

    function updateToastProgress(toast, pct) {
        if (toast && toast._bar) {
            toast._bar.style.width = Math.max(0, Math.min(100, pct)) + "%";
        }
    }

    function finishToast(toast, message, kind, duration) {
        if (!toast) return;
        toast.className = "toast" + (kind ? " toast-" + kind : "");
        const textEl = toast.querySelector(".toast-text");
        if (textEl) textEl.textContent = message;
        const track = toast.querySelector(".toast-progress-track");
        if (track) track.remove();
        dismissToast(toast, duration || 5000);
    }

    function renderAttachmentsBar(attachments) {
        if (!attachmentsBarEl) return;
        attachmentsBarEl.innerHTML = "";
        if (!attachments || !attachments.length) {
            attachmentsBarEl.hidden = true;
            return;
        }
        attachmentsBarEl.hidden = false;
        attachments.forEach(function (att) {
            attachmentsBarEl.appendChild(buildAttachmentRow(att));
        });
    }

    function buildAttachmentRow(att) {
        const row = document.createElement("div");
        row.className = "attachment-pill";

        const nameEl = document.createElement("span");
        nameEl.className = "attachment-pill-name";
        nameEl.title = att.chunks_added + " trecho(s) — " + formatBytes(att.size_bytes) + " (apenas nesta conversa)";
        nameEl.textContent = "📎 " + att.file_name + " (" + formatBytes(att.size_bytes) + ")";
        row.appendChild(nameEl);

        const removeBtn = document.createElement("button");
        removeBtn.type = "button";
        removeBtn.className = "attachment-remove-btn";
        removeBtn.title = "Remover anexo desta conversa";
        removeBtn.textContent = "×";
        removeBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            confirmRemoveAttachment(row, att);
        });
        row.appendChild(removeBtn);

        return row;
    }

    function confirmRemoveAttachment(row, att) {
        if (row.querySelector(".attachment-confirm-delete")) return;

        const confirmBar = document.createElement("div");
        confirmBar.className = "attachment-confirm-delete";

        const label = document.createElement("span");
        label.textContent = "Remover da conversa?";

        const yesBtn = document.createElement("button");
        yesBtn.type = "button";
        yesBtn.textContent = "Sim";
        yesBtn.className = "confirm-yes";

        const noBtn = document.createElement("button");
        noBtn.type = "button";
        noBtn.textContent = "Cancelar";
        noBtn.className = "confirm-no";

        confirmBar.appendChild(label);
        confirmBar.appendChild(yesBtn);
        confirmBar.appendChild(noBtn);
        row.appendChild(confirmBar);

        noBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            confirmBar.remove();
        });

        yesBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            if (!currentSessionId) {
                confirmBar.remove();
                return;
            }
            fetch("/api/sessions/" + currentSessionId + "/attachments/" + att.id, { method: "DELETE" })
                .then(function (r) {
                    if (!r.ok) {
                        return r.json().then(function (data) {
                            throw new Error(data.error || "Falha ao remover anexo.");
                        });
                    }
                    return r.json();
                })
                .then(function () {
                    row.remove();
                    if (!attachmentsBarEl.children.length) attachmentsBarEl.hidden = true;
                    showToast("Anexo removido: " + att.file_name, "success");
                })
                .catch(function (err) {
                    confirmBar.remove();
                    showToast(err.message || "Falha ao remover anexo.", "error");
                });
        });
    }

    function loadAttachmentsBar(sessionId) {
        if (!sessionId) {
            renderAttachmentsBar([]);
            return;
        }
        fetch("/api/sessions/" + sessionId + "/attachments")
            .then(function (r) { return r.json(); })
            .then(function (data) { renderAttachmentsBar(data.attachments || []); })
            .catch(function () { renderAttachmentsBar([]); });
    }

    function ensureSessionForAttach() {
        if (currentSessionId) return Promise.resolve(currentSessionId);
        return fetch("/api/sessions", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ title: "Nova conversa" }),
        })
            .then(function (r) {
                if (!r.ok) throw new Error("Não foi possível iniciar a conversa.");
                return r.json();
            })
            .then(function (data) {
                currentSessionId = data.session_id;
                markActiveSession(currentSessionId);
                refreshSessionList();
                return currentSessionId;
            });
    }

    function uploadAttachment(file) {
        ensureSessionForAttach().then(function (sessionId) {
            const toast = showToast("Enviando " + file.name + "...", "progress",
                { progress: true, sticky: true });

            const xhr = new XMLHttpRequest();
            xhr.open("POST", "/api/sessions/" + sessionId + "/attach-file");

            xhr.upload.addEventListener("progress", function (ev) {
                if (ev.lengthComputable) {
                    updateToastProgress(toast, (ev.loaded / ev.total) * 100);
                }
            });

            xhr.addEventListener("load", function () {
                let data = {};
                try { data = JSON.parse(xhr.responseText); } catch (e) { /* non-JSON, fall through */ }

                if (xhr.status >= 200 && xhr.status < 300 && data.status === "ok") {
                    finishToast(
                        toast,
                        "Adicionado " + data.chunks_added + " trecho(s) (" +
                            formatBytes(data.size_bytes) + ") de " + data.file_name,
                        "success"
                    );
                    loadAttachmentsBar(sessionId);
                } else {
                    finishToast(toast, data.error || ("Falha ao anexar " + file.name + "."), "error");
                }
            });

            xhr.addEventListener("error", function () {
                finishToast(toast, "Falha de conexão ao anexar " + file.name + ".", "error");
            });

            const formData = new FormData();
            formData.append("file", file);
            xhr.send(formData);
        }).catch(function (err) {
            showToast(err.message || "Não foi possível anexar o arquivo.", "error");
        });
    }

    function handleAttachFiles(fileList) {
        Array.prototype.forEach.call(fileList || [], function (file) {
            uploadAttachment(file);
        });
    }

    if (attachBtn && attachFileInput) {
        attachBtn.addEventListener("click", function () {
            attachFileInput.click();
        });
        attachFileInput.addEventListener("change", function () {
            handleAttachFiles(attachFileInput.files);
            attachFileInput.value = "";
        });
    }

    if (dropOverlayEl) {
        let dragCounter = 0;
        messagesEl.addEventListener("dragenter", function (ev) {
            ev.preventDefault();
            dragCounter++;
            dropOverlayEl.classList.add("drop-overlay-visible");
        });
        messagesEl.addEventListener("dragover", function (ev) {
            ev.preventDefault();
        });
        messagesEl.addEventListener("dragleave", function () {
            dragCounter = Math.max(0, dragCounter - 1);
            if (dragCounter === 0) dropOverlayEl.classList.remove("drop-overlay-visible");
        });
        messagesEl.addEventListener("drop", function (ev) {
            ev.preventDefault();
            dragCounter = 0;
            dropOverlayEl.classList.remove("drop-overlay-visible");
            if (ev.dataTransfer && ev.dataTransfer.files) {
                handleAttachFiles(ev.dataTransfer.files);
            }
        });
    }

    // --- Multi-doc scope selector ------------------------------------------
    // Sidebar folder tree (checkboxes) + header pills. Scope is per-session,
    // persisted server-side via /api/sessions/<id>/scope; `pendingScope`
    // (declared above) buffers the selection for a not-yet-created session.
    const folderTreeEl = document.getElementById("folder-tree");
    const scopePillsEl = document.getElementById("scope-pills");
    const selectAllBtn = document.getElementById("select-all-docs");
    const deselectAllBtn = document.getElementById("deselect-all-docs");
    const toggleScopeBtn = document.getElementById("toggle-scope");

    function loadDocumentTree() {
        fetch("/api/documents/tree")
            .then(function (r) {
                if (!r.ok) throw new Error("HTTP " + r.status);
                return r.json();
            })
            .then(function (data) {
                renderFolderTree(data.folders || {});
                if (currentSessionId) {
                    loadSessionScope(currentSessionId);
                } else {
                    updateScopePills(pendingScope);
                }
            })
            .catch(function (err) {
                console.error("Falha ao carregar árvore de documentos:", err);
            });
    }

    function renderFolderTree(folders) {
        if (!folderTreeEl) return;
        folderTreeEl.innerHTML = "";

        Object.keys(folders).sort().forEach(function (folderName) {
            const docs = folders[folderName];

            const folderEl = document.createElement("div");
            folderEl.className = "folder-item";

            const toggle = document.createElement("span");
            toggle.className = "folder-toggle collapsed";

            const folderLabel = document.createElement("span");
            folderLabel.textContent = folderName;
            folderLabel.style.flex = "1";

            const count = document.createElement("span");
            count.className = "doc-count";
            count.textContent = "(" + docs.length + ")";

            folderEl.appendChild(toggle);
            folderEl.appendChild(folderLabel);
            folderEl.appendChild(count);
            folderTreeEl.appendChild(folderEl);

            const docsContainer = document.createElement("div");
            docsContainer.dataset.docsFor = folderName;
            docsContainer.style.display = "none";
            docsContainer.style.flexDirection = "column";

            docs.forEach(function (doc) {
                const docLabel = document.createElement("label");
                docLabel.className = "doc-item";

                const checkbox = document.createElement("input");
                checkbox.type = "checkbox";
                checkbox.className = "doc-checkbox";
                checkbox.dataset.path = doc.path;

                const docName = document.createElement("span");
                docName.textContent = doc.name;

                docLabel.appendChild(checkbox);
                docLabel.appendChild(docName);
                docsContainer.appendChild(docLabel);

                checkbox.addEventListener("change", updateScopeSelection);
            });

            folderTreeEl.appendChild(docsContainer);

            folderEl.addEventListener("click", function () {
                const isExpanded = toggle.classList.contains("expanded");
                toggle.classList.toggle("expanded", !isExpanded);
                toggle.classList.toggle("collapsed", isExpanded);
                docsContainer.style.display = isExpanded ? "none" : "flex";
            });
        });
    }

    function updateScopeSelection() {
        const checked = Array.prototype.map.call(
            document.querySelectorAll(".doc-checkbox:checked"),
            function (el) { return el.dataset.path; }
        );

        updateScopePills(checked);

        if (currentSessionId) {
            fetch("/api/sessions/" + currentSessionId + "/scope", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ selected_docs: checked }),
            }).catch(function (err) {
                console.error("Falha ao salvar escopo:", err);
            });
        } else {
            pendingScope = checked;
        }
    }

    function updateScopePills(selectedDocs) {
        if (!scopePillsEl) return;
        scopePillsEl.innerHTML = "";

        const allDocs = document.querySelectorAll(".doc-checkbox").length;

        if (!selectedDocs.length) {
            const msg = document.createElement("span");
            msg.className = "scope-summary";
            msg.textContent = allDocs ? "Todos os documentos (" + allDocs + ")" : "Nenhum documento indexado";
            scopePillsEl.appendChild(msg);
            return;
        }

        const summary = document.createElement("span");
        summary.className = "scope-summary";
        summary.textContent = selectedDocs.length + " de " + allDocs + " docs";
        scopePillsEl.appendChild(summary);

        const pillsContainer = document.createElement("div");
        pillsContainer.className = "doc-pills";

        selectedDocs.slice(0, 3).forEach(function (path) {
            const name = path.split("/").pop() || path;
            const knownCheckbox = document.querySelector('.doc-checkbox[data-path="' + CSS.escape(path) + '"]');

            const pill = document.createElement("span");
            pill.className = "doc-pill" + (knownCheckbox ? "" : " missing");
            pill.title = path + (knownCheckbox ? "" : " (não encontrado no acervo atual)");
            pill.textContent = name;

            const removeBtn = document.createElement("span");
            removeBtn.className = "doc-pill-remove";
            removeBtn.textContent = "×";
            removeBtn.addEventListener("click", function (ev) {
                ev.stopPropagation();
                if (knownCheckbox) {
                    knownCheckbox.checked = false;
                    updateScopeSelection();
                } else {
                    // Doc no longer in the tree: drop it directly from the buffer/session.
                    const next = selectedDocs.filter(function (p) { return p !== path; });
                    updateScopePills(next);
                    if (currentSessionId) {
                        fetch("/api/sessions/" + currentSessionId + "/scope", {
                            method: "POST",
                            headers: { "Content-Type": "application/json" },
                            body: JSON.stringify({ selected_docs: next }),
                        }).catch(function () {});
                    } else {
                        pendingScope = next;
                    }
                }
            });
            pill.appendChild(removeBtn);
            pillsContainer.appendChild(pill);
        });

        if (selectedDocs.length > 3) {
            const more = document.createElement("span");
            more.className = "doc-pill";
            more.textContent = "+" + (selectedDocs.length - 3) + " mais";
            pillsContainer.appendChild(more);
        }

        scopePillsEl.appendChild(pillsContainer);
    }

    function loadSessionScope(sessionId) {
        fetch("/api/sessions/" + sessionId + "/scope")
            .then(function (r) {
                if (!r.ok) throw new Error("HTTP " + r.status);
                return r.json();
            })
            .then(function (data) {
                const selectedDocs = data.selected_docs || [];
                Array.prototype.forEach.call(document.querySelectorAll(".doc-checkbox"), function (cb) {
                    cb.checked = selectedDocs.indexOf(cb.dataset.path) !== -1;
                });
                updateScopePills(selectedDocs);
            })
            .catch(function (err) {
                console.error("Falha ao carregar escopo da sessão:", err);
            });
    }

    if (selectAllBtn) {
        selectAllBtn.addEventListener("click", function () {
            Array.prototype.forEach.call(document.querySelectorAll(".doc-checkbox"), function (el) {
                el.checked = true;
            });
            updateScopeSelection();
        });
    }

    if (deselectAllBtn) {
        deselectAllBtn.addEventListener("click", function () {
            Array.prototype.forEach.call(document.querySelectorAll(".doc-checkbox"), function (el) {
                el.checked = false;
            });
            updateScopeSelection();
        });
    }

    if (toggleScopeBtn) {
        toggleScopeBtn.addEventListener("click", function () {
            const isExpanded = toggleScopeBtn.getAttribute("aria-expanded") === "true";
            Array.prototype.forEach.call(document.querySelectorAll(".folder-toggle"), function (t) {
                t.classList.toggle("expanded", !isExpanded);
                t.classList.toggle("collapsed", isExpanded);
            });
            Array.prototype.forEach.call(document.querySelectorAll("[data-docs-for]"), function (el) {
                el.style.display = isExpanded ? "none" : "flex";
            });
            toggleScopeBtn.setAttribute("aria-expanded", String(!isExpanded));
        });
    }

    // --- Context window monitor (M5) ----------------------------------------
    // Per-turn prompt size vs. the model's num_ctx (CONTEXT_WINDOW). Estimated
    // from char counts until the "stats" SSE event (Ollama's exact
    // prompt_eval_count) arrives and replaces the estimate for that turn.
    const contextMonitorEl = document.getElementById("context-monitor");
    const contextBarEl = document.getElementById("context-bar");
    const contextTextEl = document.getElementById("context-text");
    let lastContextUsage = null;

    function renderContextUsage(data, exact) {
        if (!contextMonitorEl) return;
        lastContextUsage = data;

        const percent = Math.min(data.usage_percent, 100);
        contextBarEl.style.width = percent + "%";
        contextMonitorEl.className = "context-monitor context-" + data.status;

        const kFmt = function (n) { return (n / 1000).toFixed(1) + "K"; };
        contextTextEl.textContent =
            kFmt(data.total_tokens) + "/" + kFmt(data.available_tokens) +
            " (" + Math.round(data.usage_percent) + "%)" + (exact ? " [exato]" : " [est]");

        const b = data.breakdown;
        const lines = [
            "Prompt do sistema: ~" + b.system_prompt + " tokens",
            "Documentos recuperados: ~" + b.retrieved_docs + " tokens",
            "Pergunta: ~" + b.query + " tokens",
        ];
        if (b.session_memory > 0) lines.push("Memória da conversa: ~" + b.session_memory + " tokens");
        if (b.global_memory > 0) lines.push("Memória global: ~" + b.global_memory + " tokens");
        lines.push("─────────────────────");
        lines.push("Usado: " + data.total_tokens + " / " + data.available_tokens +
            " (" + data.usage_percent + "%)");
        lines.push("Janela: " + data.context_window + " tokens (" +
            data.output_reserve + " reservados p/ resposta)");
        contextMonitorEl.title = lines.join("\n");

        if (data.status === "critical") {
            console.error("%c[Contexto] Uso CRÍTICO (" + data.usage_percent + "%). " +
                "Considere desativar memória ou reduzir o escopo de documentos.",
                "color: red; font-weight: bold;");
        } else if (data.status === "warning") {
            console.warn("[Contexto] Aviso: uso em " + data.usage_percent + "%.");
        }
    }

    function updateContextUsage(promptEstimate) {
        if (!contextMonitorEl || !currentSessionId) return;
        fetch("/api/sessions/" + currentSessionId + "/context-usage", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(promptEstimate || {}),
        })
            .then(function (r) { return r.json(); })
            .then(function (data) { renderContextUsage(data, false); })
            .catch(function (err) { console.error("Falha ao calcular uso de contexto:", err); });
    }

    function updateContextUsageExact(promptEvalCount) {
        if (!contextMonitorEl || !lastContextUsage || typeof promptEvalCount !== "number") return;
        const usage = Object.assign({}, lastContextUsage, {
            total_tokens: promptEvalCount,
            usage_percent: Math.round((promptEvalCount / lastContextUsage.available_tokens) * 1000) / 10,
        });
        if (usage.usage_percent < 60) usage.status = "safe";
        else if (usage.usage_percent < 75) usage.status = "caution";
        else if (usage.usage_percent < 85) usage.status = "warning";
        else usage.status = "critical";
        renderContextUsage(usage, true);
    }

    // --- Manual "Compact now" button (backlog item 10) ----------------------
    // Triggers the same summarize-and-truncate logic as the item 8
    // auto-trigger (server-side, see memory.compact_session), on demand.
    const compactBtn = document.getElementById("compact-btn");

    if (compactBtn) {
        compactBtn.addEventListener("click", function () {
            if (!currentSessionId) {
                showToast("Inicie uma conversa antes de compactar o contexto.", "error");
                return;
            }
            compactBtn.disabled = true;
            fetch("/api/sessions/" + currentSessionId + "/compact", { method: "POST" })
                .then(function (r) {
                    if (!r.ok) {
                        return r.json().then(function (data) {
                            throw new Error(data.error || "Falha ao compactar contexto.");
                        });
                    }
                    return r.json();
                })
                .then(function (data) {
                    showToast(
                        "🗜️ Contexto compactado (turno " + data.checkpoint.turn + ").",
                        "success",
                        { duration: 6000 }
                    );
                    if (memoryPanel && !memoryPanel.hasAttribute("hidden")) refreshMemoryPanel();
                    updateContextUsage({});
                })
                .catch(function (err) {
                    showToast(err.message || "Falha ao compactar contexto.", "error");
                })
                .finally(function () {
                    compactBtn.disabled = false;
                });
        });
    }

    // --- Session memory disclosure (M3 mini-UI) -----------------------------
    const memoryBtn = document.getElementById("memory-disclosure-btn");
    const memoryPanel = document.getElementById("memory-disclosure-panel");

    function renderMemoryFacts(facts) {
        memoryPanel.innerHTML = "";
        if (!facts.length) {
            const empty = document.createElement("div");
            empty.className = "memory-empty";
            empty.textContent = "Nenhum fato memorizado nesta conversa ainda.";
            memoryPanel.appendChild(empty);
            return;
        }
        facts.forEach(function (fact) {
            const row = document.createElement("div");
            row.className = "memory-fact";

            const text = document.createElement("span");
            text.textContent = fact.content;

            const remove = document.createElement("span");
            remove.className = "memory-fact-remove";
            remove.textContent = "×";
            remove.title = "Esquecer este fato";
            remove.addEventListener("click", function () {
                fetch("/api/sessions/" + currentSessionId + "/memory/" + fact.id, { method: "DELETE" })
                    .then(function () { row.remove(); })
                    .catch(function (err) { console.error(err); });
            });

            row.appendChild(text);
            row.appendChild(remove);
            memoryPanel.appendChild(row);
        });
    }

    // Shared by the 🧠 disclosure toggle above and by post-compaction
    // refreshes (auto via SSE "compact" event, manual via the 🗜️ button)
    // so the panel's fact list never goes stale after a checkpoint is added.
    function refreshMemoryPanel() {
        if (!currentSessionId) {
            renderMemoryFacts([]);
            return;
        }
        fetch("/api/sessions/" + currentSessionId + "/memory")
            .then(function (r) { return r.json(); })
            .then(function (data) { renderMemoryFacts(data.facts || []); })
            .catch(function () { renderMemoryFacts([]); });
    }

    if (memoryBtn) {
        memoryBtn.addEventListener("click", function (ev) {
            ev.stopPropagation();
            const isOpen = !memoryPanel.hasAttribute("hidden");
            if (isOpen) {
                memoryPanel.setAttribute("hidden", "");
                return;
            }
            refreshMemoryPanel();
            memoryPanel.removeAttribute("hidden");
        });

        document.addEventListener("click", function (ev) {
            if (!memoryPanel.hasAttribute("hidden") &&
                !memoryPanel.contains(ev.target) && ev.target !== memoryBtn) {
                memoryPanel.setAttribute("hidden", "");
            }
        });
    }

    loadDocumentTree();
    loadSessionsPage(true);

    setStatus("idle");
})();

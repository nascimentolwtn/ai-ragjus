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

    function createCopyButton(contentEl) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "copy-btn";
        btn.textContent = "📋"; // 📋
        btn.title = "Copiar resposta";
        btn.setAttribute("aria-label", "Copiar resposta");

        function showFeedback(ok) {
            btn.textContent = ok ? "✅" : "❌"; // ✅ / ❌
            btn.title = ok ? "Copiado!" : "Falhou ao copiar";
            btn.setAttribute("aria-label", btn.title);
            btn.classList.toggle("copied", ok);
            setTimeout(function () {
                btn.textContent = "📋"; // 📋
                btn.title = "Copiar resposta";
                btn.setAttribute("aria-label", "Copiar resposta");
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
            contentEl.innerHTML = renderMarkdown(content || "");
            rightGroup.appendChild(createCopyButton(contentEl));
        } else {
            contentEl.textContent = content || "";
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
                loadSessionScope(sessionId);
            })
            .catch(function (err) {
                addMessage("error", "Falha ao carregar conversa: " + err.message);
            });
    }

    newChatBtn.addEventListener("click", function () {
        currentSessionId = null;
        pendingScope = [];
        clearMessages();
        addMessage("assistant",
            "Nova conversa iniciada. Faça uma pergunta sobre o seu acervo de documentos.");
        markActiveSession(null);
        Array.prototype.forEach.call(document.querySelectorAll(".doc-checkbox"), function (el) {
            el.checked = false;
        });
        updateScopePills([]);
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
                } else if (event.type === "token") {
                    accumulated += event.content || "";
                    assistantContentEl.dataset.raw = accumulated;
                    assistantContentEl.innerHTML = renderMarkdown(accumulated);
                    scrollToBottom();
                } else if (event.type === "sources") {
                    sources = event.content || [];
                } else if (event.type === "error") {
                    sawError = true;
                    accumulated += (accumulated ? "\n" : "") + "[Erro] " + event.content;
                    assistantContentEl.dataset.raw = accumulated;
                    assistantContentEl.innerHTML = renderMarkdown(accumulated);
                    assistantContentEl.closest(".message").classList.add("error");
                }
                // "done" is a no-op; the loop ends when the stream closes.
            });
        } catch (err) {
            sawError = true;
            accumulated += (accumulated ? "\n" : "") + "[Erro de conexão] " + err.message;
            assistantContentEl.dataset.raw = accumulated;
            assistantContentEl.innerHTML = renderMarkdown(accumulated);
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

    loadDocumentTree();

    setStatus("idle");
})();

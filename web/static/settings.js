/**
 * AI-RAGJus Web GUI - settings page (M4: global memory inspector).
 */
(function () {
    "use strict";

    const tableBody = document.getElementById("memory-table-body");
    const addForm = document.getElementById("memory-add-form");
    const keyInput = document.getElementById("memory-key-input");
    const valueInput = document.getElementById("memory-value-input");

    function buildRow(entry) {
        const tr = document.createElement("tr");
        tr.dataset.id = entry.id;

        const keyTd = document.createElement("td");
        keyTd.textContent = entry.key;

        const valueTd = document.createElement("td");
        valueTd.textContent = entry.value;
        valueTd.className = "memory-value-cell";

        const sourceTd = document.createElement("td");
        const badge = document.createElement("span");
        badge.className = "source-badge source-" + entry.source;
        badge.textContent = entry.source;
        sourceTd.appendChild(badge);

        const enabledTd = document.createElement("td");
        const toggle = document.createElement("input");
        toggle.type = "checkbox";
        toggle.checked = !!entry.enabled;
        toggle.addEventListener("change", function () {
            fetch("/api/memory/global/" + entry.id, {
                method: "PATCH",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ enabled: toggle.checked }),
            }).catch(function () { toggle.checked = !toggle.checked; });
        });
        enabledTd.appendChild(toggle);

        const actionsTd = document.createElement("td");

        const editBtn = document.createElement("button");
        editBtn.type = "button";
        editBtn.className = "table-action-btn";
        editBtn.textContent = "Editar";
        editBtn.addEventListener("click", function () { startEdit(tr, entry); });

        const delBtn = document.createElement("button");
        delBtn.type = "button";
        delBtn.className = "table-action-btn danger";
        delBtn.textContent = "Excluir";
        delBtn.addEventListener("click", function () {
            if (!confirm('Excluir "' + entry.key + '"?')) return;
            fetch("/api/memory/global/" + entry.id, { method: "DELETE" })
                .then(function () { tr.remove(); })
                .catch(function (err) { console.error(err); });
        });

        actionsTd.appendChild(editBtn);
        actionsTd.appendChild(delBtn);

        tr.appendChild(keyTd);
        tr.appendChild(valueTd);
        tr.appendChild(sourceTd);
        tr.appendChild(enabledTd);
        tr.appendChild(actionsTd);
        return tr;
    }

    function startEdit(tr, entry) {
        const valueTd = tr.querySelector(".memory-value-cell");
        const original = entry.value;

        const textarea = document.createElement("textarea");
        textarea.className = "inline-edit";
        textarea.value = original;
        valueTd.textContent = "";
        valueTd.appendChild(textarea);
        textarea.focus();

        function commit() {
            const newValue = textarea.value.trim();
            if (!newValue || newValue === original) {
                valueTd.textContent = original;
                return;
            }
            fetch("/api/memory/global/" + entry.id, {
                method: "PATCH",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ value: newValue }),
            })
                .then(function (r) { return r.json(); })
                .then(function (data) {
                    entry.value = (data.entry && data.entry.value) || newValue;
                    valueTd.textContent = entry.value;
                })
                .catch(function () { valueTd.textContent = original; });
        }

        textarea.addEventListener("blur", commit);
        textarea.addEventListener("keydown", function (ev) {
            if (ev.key === "Enter" && !ev.shiftKey) { ev.preventDefault(); textarea.blur(); }
        });
    }

    function loadMemory() {
        fetch("/api/memory/global")
            .then(function (r) { return r.json(); })
            .then(function (data) {
                tableBody.innerHTML = "";
                const entries = (data.enabled || []).concat(data.disabled || []);
                entries.forEach(function (entry) {
                    tableBody.appendChild(buildRow(entry));
                });
            })
            .catch(function (err) { console.error("Falha ao carregar memória global:", err); });
    }

    addForm.addEventListener("submit", function (ev) {
        ev.preventDefault();
        const key = keyInput.value.trim();
        const value = valueInput.value.trim();
        if (!key || !value) return;

        fetch("/api/memory/global", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ key: key, value: value }),
        })
            .then(function (r) { return r.json(); })
            .then(function () {
                keyInput.value = "";
                valueInput.value = "";
                loadMemory();
            })
            .catch(function (err) { console.error("Falha ao adicionar fato:", err); });
    });

    loadMemory();

    // --- Auto-compaction settings (backlog item 8) --------------------------
    const autoCompactForm = document.getElementById("auto-compact-form");
    const autoCompactEnabledInput = document.getElementById("auto-compact-enabled");
    const autoCompactThresholdInput = document.getElementById("auto-compact-threshold");
    const autoCompactStatusEl = document.getElementById("auto-compact-status");

    function setAutoCompactStatus(text, kind) {
        if (!autoCompactStatusEl) return;
        autoCompactStatusEl.textContent = text;
        autoCompactStatusEl.className = "auto-compact-status" + (kind ? " " + kind : "");
    }

    if (autoCompactForm) {
        autoCompactForm.addEventListener("submit", function (ev) {
            ev.preventDefault();
            fetch("/api/settings/auto-compact", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    enabled: autoCompactEnabledInput.checked,
                    threshold: Number(autoCompactThresholdInput.value),
                }),
            })
                .then(function (r) {
                    if (!r.ok) {
                        return r.json().then(function (data) {
                            throw new Error(data.error || "Falha ao salvar.");
                        });
                    }
                    return r.json();
                })
                .then(function (data) {
                    autoCompactThresholdInput.value = data.threshold;
                    setAutoCompactStatus("Salvo.", "success");
                    setTimeout(function () { setAutoCompactStatus(""); }, 3000);
                })
                .catch(function (err) {
                    setAutoCompactStatus(err.message || "Falha ao salvar.", "error");
                });
        });
    }

    // --- Prompt clarification layer -----------------------------------------
    const promptClarificationForm = document.getElementById("prompt-clarification-form");
    const promptClarificationEnabledInput = document.getElementById("prompt-clarification-enabled");
    const promptClarificationStatusEl = document.getElementById("prompt-clarification-status");

    function setPromptClarificationStatus(text, kind) {
        if (!promptClarificationStatusEl) return;
        promptClarificationStatusEl.textContent = text;
        promptClarificationStatusEl.className = "auto-compact-status" + (kind ? " " + kind : "");
    }

    if (promptClarificationForm) {
        promptClarificationForm.addEventListener("submit", function (ev) {
            ev.preventDefault();
            fetch("/api/settings/prompt-clarification", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ enabled: promptClarificationEnabledInput.checked }),
            })
                .then(function (r) {
                    if (!r.ok) {
                        return r.json().then(function (data) {
                            throw new Error(data.error || "Falha ao salvar.");
                        });
                    }
                    return r.json();
                })
                .then(function () {
                    setPromptClarificationStatus("Salvo.", "success");
                    setTimeout(function () { setPromptClarificationStatus(""); }, 3000);
                })
                .catch(function (err) {
                    setPromptClarificationStatus(err.message || "Falha ao salvar.", "error");
                });
        });
    }
})();

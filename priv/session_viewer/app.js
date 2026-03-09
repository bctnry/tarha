// Session Viewer Application
class SessionViewer {
    constructor() {
        // Empty string means same-origin (served from the same host as the API)
        // This avoids CORS issues when viewer is served by the HTTP server
        this.apiUrl = document.getElementById('api-url').value || '';
        this.autoRefresh = false;
        this.autoRefreshInterval = null;
        this.activeSessions = [];
        this.savedSessions = [];
        this.selectedSession = null;

        this.init();
    }

    init() {
        // Bind event listeners
        document.getElementById('refresh-btn').addEventListener('click', () => this.refresh());
        document.getElementById('auto-refresh-toggle').addEventListener('click', () => this.toggleAutoRefresh());
        document.getElementById('api-url').addEventListener('change', (e) => {
            this.apiUrl = e.target.value;
            this.refresh();
        });
        document.getElementById('close-detail').addEventListener('click', () => this.closeDetail());

        // Initial load
        this.refresh();
    }

    async fetchJson(endpoint) {
        // If apiUrl is empty, use relative URLs (same-origin)
        // Otherwise prepend the apiUrl
        const url = this.apiUrl ? `${this.apiUrl}${endpoint}` : endpoint;
        try {
            const response = await fetch(url, {
                method: 'GET',
                headers: {
                    'Accept': 'application/json'
                }
            });
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }
            return await response.json();
        } catch (error) {
            console.error('Fetch error:', error);
            throw error;
        }
    }

    async postJson(endpoint, data = {}) {
        const url = this.apiUrl ? `${this.apiUrl}${endpoint}` : endpoint;
        try {
            const response = await fetch(url, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json'
                },
                body: JSON.stringify(data)
            });
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }
            return await response.json();
        } catch (error) {
            console.error('Post error:', error);
            throw error;
        }
    }

    async refresh() {
        const container = document.getElementById('sessions-container');
        container.innerHTML = '<div class="loading">Loading sessions...</div>';

        try {
            // Fetch both active and saved sessions in parallel
            const [activeData, savedData, statusData] = await Promise.all([
                this.fetchJson('/sessions/active').catch(() => ({ sessions: [] })),
                this.fetchJson('/sessions').catch(() => ({ sessions: [] })),
                this.fetchJson('/status').catch(() => ({}))
            ]);

            this.activeSessions = activeData.sessions || [];
            
            // Handle both formats: session IDs as strings or objects
            let savedSessions = savedData.sessions || [];
            if (savedSessions.length > 0 && typeof savedSessions[0] === 'string') {
                // Old API format: returns session IDs as strings
                // Fetch details for each session
                const sessionDetails = await Promise.all(
                    savedSessions.slice(0, 50).map(id => 
                        this.fetchJson(`/session/${id}`).catch(() => null)
                    )
                );
                savedSessions = sessionDetails
                    .filter(s => s && !s.error)
                    .map(s => ({
                        id: s.id,
                        model: s.model || 'unknown',
                        messages: s.message_count || s.messages || 0,
                        total_tokens: s.total_tokens || 0,
                        tool_calls: s.tool_calls || 0,
                        working_dir: s.working_dir || ''
                    }));
            }
            this.savedSessions = savedSessions;
            
            // Get active session IDs for comparison
            const activeIds = new Set(this.activeSessions.map(s => s.id));

            this.updateStats(this.activeSessions, this.savedSessions, statusData);
            this.renderSessions(this.activeSessions, this.savedSessions, activeIds);

            // Update last refreshed time
            document.getElementById('last-updated').textContent = new Date().toLocaleTimeString();
        } catch (error) {
            container.innerHTML = `
                <div class="error">
                    <p>❌ Error connecting to API: ${error.message}</p>
                    <p>Make sure the coding agent HTTP server is running at ${this.apiUrl}</p>
                </div>
            `;
        }
    }

    updateStats(activeSessions, savedSessions, status) {
        document.getElementById('active-sessions').textContent = activeSessions.length;
        document.getElementById('total-sessions').textContent = savedSessions.length;
    }

    renderSessions(activeSessions, savedSessions, activeIds) {
        const container = document.getElementById('sessions-container');

        if (activeSessions.length === 0 && savedSessions.length === 0) {
            container.innerHTML = `
                <div class="empty-state">
                    <div class="icon">📭</div>
                    <p>No sessions found</p>
                    <p style="margin-top: 10px; font-size: 0.9rem;">Sessions will appear here when created</p>
                </div>
            `;
            return;
        }

        // Render active sessions first, then saved (non-active) sessions
        let html = '';
        
        if (activeSessions.length > 0) {
            html += '<div class="session-section"><h3 class="section-title">🟢 Active Sessions</h3>';
            html += '<div class="sessions-grid">';
            html += activeSessions.map(session => this.renderSessionCard(session, true)).join('');
            html += '</div></div>';
        }

        // Saved sessions that are not currently active
        const onlySaved = savedSessions.filter(s => {
            const id = s.id || s;
            return !activeIds.has(id);
        });
        if (onlySaved.length > 0) {
            html += '<div class="session-section"><h3 class="section-title">💾 Saved Sessions</h3>';
            html += '<div class="sessions-grid">';
            html += onlySaved.map(session => this.renderSavedSessionCard(session)).join('');
            html += '</div></div>';
        }

        container.innerHTML = html;

        // Bind click events to session cards
        container.querySelectorAll('.session-card').forEach(card => {
            card.addEventListener('click', (e) => {
                if (!e.target.closest('button')) {
                    this.showSessionDetail(card.dataset.sessionId, card.dataset.isActive === 'true');
                }
            });
        });

        // Bind action buttons
        container.querySelectorAll('.btn-halt').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.haltSession(btn.dataset.sessionId);
            });
        });

        container.querySelectorAll('.btn-stats').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.showSessionDetail(btn.dataset.sessionId, true);
            });
        });

        container.querySelectorAll('.btn-load').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.loadSession(btn.dataset.sessionId);
            });
        });

        container.querySelectorAll('.btn-delete').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.deleteSession(btn.dataset.sessionId);
            });
        });
    }

    renderSessionCard(session, isActive) {
        const sessionId = session.id || session;
        const isBusy = session.busy || false;
        const statusClass = isBusy ? 'busy' : 'idle';
        const statusText = isBusy ? 'Busy' : 'Idle';
        
        return `
            <div class="session-card ${isActive ? 'active' : ''}" data-session-id="${this.escapeHtml(sessionId)}" data-is-active="${isActive}">
                <div class="session-header">
                    <span class="session-id">${this.escapeHtml(this.truncateId(sessionId))}</span>
                    <span class="session-status">
                        <span class="status-dot ${statusClass}"></span>
                        ${statusText}
                    </span>
                </div>
                <div class="session-info">
                    <div class="info-row">
                        <span class="info-label">Model:</span>
                        <span class="info-value model">${this.escapeHtml(session.model || 'unknown')}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Messages:</span>
                        <span class="info-value">${session.message_count || session.messages || 0}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Tokens:</span>
                        <span class="info-value tokens">${this.formatTokens(session.total_tokens || session.tokens)}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Tool Calls:</span>
                        <span class="info-value">${session.tool_calls || 0}</span>
                    </div>
                </div>
                <div class="session-actions">
                    <button class="btn-secondary btn-stats" data-session-id="${this.escapeHtml(sessionId)}">Details</button>
                    ${isActive ? `<button class="btn-danger btn-halt" data-session-id="${this.escapeHtml(sessionId)}">Halt</button>` : ''}
                </div>
            </div>
        `;
    }

    renderSavedSessionCard(session) {
        const sessionId = session.id || session;
        const model = session.model || 'unknown';
        const messages = session.messages || 0;
        const tokens = session.total_tokens || session.prompt_tokens || 0;
        const toolCalls = session.tool_calls || 0;
        
        return `
            <div class="session-card saved" data-session-id="${this.escapeHtml(sessionId)}" data-is-active="false">
                <div class="session-header">
                    <span class="session-id">${this.escapeHtml(this.truncateId(sessionId))}</span>
                    <span class="session-status">
                        <span class="status-dot saved"></span>
                        Saved
                    </span>
                </div>
                <div class="session-info">
                    <div class="info-row">
                        <span class="info-label">Model:</span>
                        <span class="info-value model">${this.escapeHtml(model)}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Messages:</span>
                        <span class="info-value">${messages}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Tokens:</span>
                        <span class="info-value tokens">${this.formatTokens(tokens)}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Tool Calls:</span>
                        <span class="info-value">${toolCalls}</span>
                    </div>
                </div>
                <div class="session-actions">
                    <button class="btn-primary btn-load" data-session-id="${this.escapeHtml(sessionId)}">Load</button>
                    <button class="btn-danger btn-delete" data-session-id="${this.escapeHtml(sessionId)}">Delete</button>
                </div>
            </div>
        `;
    }

    async showSessionDetail(sessionId, isActive) {
        const detailPanel = document.getElementById('session-detail');
        const detailContent = document.getElementById('detail-content');
        
        detailPanel.style.display = 'block';
        detailContent.innerHTML = '<div class="loading">Loading session details...</div>';

        try {
            const data = await this.fetchJson(`/session/${sessionId}`);
            this.selectedSession = sessionId;

            let html = `
                <div class="detail-section">
                    <h3>Session Info</h3>
                    <div class="info-row">
                        <span class="info-label">ID:</span>
                        <span class="info-value">${this.escapeHtml(sessionId)}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Model:</span>
                        <span class="info-value model">${this.escapeHtml(data.model || 'unknown')}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Status:</span>
                        <span class="info-value">${data.busy ? 'Busy' : 'Idle'}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Context Window:</span>
                        <span class="info-value">${this.formatNumber(data.context_window || 0)}</span>
                    </div>
            `;

            if (data.working_dir) {
                html += `
                    <div class="info-row">
                        <span class="info-label">Working Dir:</span>
                        <span class="info-value" style="font-size: 0.8rem; word-break: break-all;">${this.escapeHtml(data.working_dir)}</span>
                    </div>
                `;
            }

            html += '</div>';

            if (data.open_files && data.open_files.length > 0) {
                html += `
                    <div class="detail-section">
                        <h3>Open Files (${data.open_files.length})</h3>
                        <ul class="files-list">
                            ${data.open_files.map(f => `<li>${this.escapeHtml(f)}</li>`).join('')}
                        </ul>
                    </div>
                `;
            }

            if (data.messages && data.messages.length > 0) {
                html += `
                    <div class="detail-section">
                        <h3>Messages (${data.messages.length})</h3>
                        <ul class="message-list">
                            ${this.renderMessages(data.messages)}
                        </ul>
                    </div>
                `;
            }

            detailContent.innerHTML = html;
        } catch (error) {
            detailContent.innerHTML = `
                <div class="error">
                    <p>❌ Error loading session: ${error.message}</p>
                </div>
            `;
        }
    }

    renderMessages(messages) {
        return messages.slice(-20).reverse().map(msg => {
            const role = msg.role || 'unknown';
            const content = msg.content || '';
            const truncated = content.length > 500 ? content.substring(0, 500) + '...' : content;
            
            return `
                <li class="message-item">
                    <div class="message-role ${role}">${this.escapeHtml(role)}</div>
                    <div class="message-content">${this.escapeHtml(truncated)}</div>
                </li>
            `;
        }).join('');
    }

    async haltSession(sessionId) {
        if (!confirm(`Are you sure you want to halt session ${this.truncateId(sessionId)}?`)) {
            return;
        }

        try {
            await this.postJson(`/session/${sessionId}/halt`, {});
            await this.refresh();
        } catch (error) {
            alert(`Error halting session: ${error.message}`);
        }
    }

    async loadSession(sessionId) {
        if (!confirm(`Load session ${this.truncateId(sessionId)}?`)) {
            return;
        }

        try {
            const result = await this.postJson(`/session/${sessionId}/load`, {});
            alert(`Session loaded: ${result.session_id}`);
            await this.refresh();
        } catch (error) {
            alert(`Error loading session: ${error.message}`);
        }
    }

    async deleteSession(sessionId) {
        if (!confirm(`Delete saved session ${this.truncateId(sessionId)}? This cannot be undone.`)) {
            return;
        }

        try {
            await this.postJson(`/session/${sessionId}/delete`, {});
            await this.refresh();
        } catch (error) {
            alert(`Error deleting session: ${error.message}`);
        }
    }

    closeDetail() {
        document.getElementById('session-detail').style.display = 'none';
        this.selectedSession = null;
    }

    toggleAutoRefresh() {
        const btn = document.getElementById('auto-refresh-toggle');
        this.autoRefresh = !this.autoRefresh;

        if (this.autoRefresh) {
            btn.textContent = 'Auto: ON';
            btn.classList.add('btn-primary');
            btn.classList.remove('btn-secondary');
            this.autoRefreshInterval = setInterval(() => this.refresh(), 5000);
        } else {
            btn.textContent = 'Auto: OFF';
            btn.classList.remove('btn-primary');
            btn.classList.add('btn-secondary');
            if (this.autoRefreshInterval) {
                clearInterval(this.autoRefreshInterval);
                this.autoRefreshInterval = null;
            }
        }
    }

    truncateId(id) {
        if (!id) return 'unknown';
        const str = String(id);
        return str.length > 12 ? str.substring(0, 12) + '...' : str;
    }

    formatTokens(tokens) {
        if (!tokens) return '0';
        return this.formatNumber(tokens);
    }

    formatNumber(num) {
        if (!num) return '0';
        return num.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    }

    escapeHtml(text) {
        if (typeof text !== 'string') {
            text = String(text);
        }
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
}

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    window.sessionViewer = new SessionViewer();
});
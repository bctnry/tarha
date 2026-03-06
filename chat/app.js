const API_URL = 'http://localhost:8080';

let currentSessionId = null;
let isLoading = false;

document.addEventListener('DOMContentLoaded', () => {
    initEventListeners();
    checkHealth();
});

function initEventListeners() {
    const form = document.getElementById('chat-form');
    const messageInput = document.getElementById('message-input');
    const toolsBtn = document.getElementById('tools-btn');
    const clearBtn = document.getElementById('clear-btn');
    const statusBtn = document.getElementById('status-btn');
    const toolsClose = document.getElementById('tools-close');
    const statusClose = document.getElementById('status-close');
    const toolsModal = document.getElementById('tools-modal');
    const statusModal = document.getElementById('status-modal');

    form.addEventListener('submit', handleSubmit);
    
    messageInput.addEventListener('input', autoResize);
    messageInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            form.dispatchEvent(new Event('submit'));
        }
    });

    toolsBtn.addEventListener('click', showTools);
    clearBtn.addEventListener('click', clearConversation);
    statusBtn.addEventListener('click', showStatus);

    toolsClose.addEventListener('click', () => toolsModal.style.display = 'none');
    statusClose.addEventListener('click', () => statusModal.style.display = 'none');

    window.addEventListener('click', (e) => {
        if (e.target === toolsModal) toolsModal.style.display = 'none';
        if (e.target === statusModal) statusModal.style.display = 'none';
    });
}

async function checkHealth() {
    try {
        const response = await fetch(`${API_URL}/health`);
        const data = await response.json();
        updateStatus('connected', 'Connected');
    } catch (error) {
        updateStatus('error', 'Disconnected');
        console.error('Health check failed:', error);
    }
}

function updateStatus(status, text) {
    const statusDot = document.querySelector('.status-dot');
    const statusText = document.querySelector('.status-text');
    
    statusDot.className = 'status-dot ' + status;
    statusText.textContent = text;
}

async function handleSubmit(e) {
    e.preventDefault();
    
    if (isLoading) return;

    const input = document.getElementById('message-input');
    const message = input.value.trim();
    
    if (!message) return;

    isLoading = true;
    input.value = '';
    autoResize.call(input);
    
    addMessage('user', message);
    showThinking(true);

    try {
        const body = { message };
        if (currentSessionId) {
            body.session_id = currentSessionId;
        }

        const response = await fetch(`${API_URL}/chat`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });

        const data = await response.json();

        if (data.error) {
            addMessage('error', `Error: ${data.error}`);
        } else {
            currentSessionId = data.session_id;
            
            if (data.thinking) {
                addMessage('thinking', data.thinking);
            }
            
            addMessage('assistant', data.response);
        }
    } catch (error) {
        addMessage('error', `Network error: ${error.message}`);
    } finally {
        isLoading = false;
        showThinking(false);
    }
}

function addMessage(role, content) {
    const messages = document.getElementById('messages');
    const div = document.createElement('div');
    div.className = `message ${role}`;
    
    const contentDiv = document.createElement('div');
    contentDiv.className = 'message-content';
    
    if (role === 'thinking') {
        contentDiv.innerHTML = `<strong>Thinking:</strong><br><pre>${escapeHtml(content)}</pre>`;
    } else if (role === 'error') {
        contentDiv.textContent = content;
        div.style.borderColor = '#e74c3c';
    } else {
        contentDiv.textContent = content;
    }
    
    div.appendChild(contentDiv);
    messages.appendChild(div);
    messages.scrollTop = messages.scrollHeight;
}

function showThinking(show) {
    const thinking = document.getElementById('thinking');
    thinking.style.display = show ? 'block' : 'none';
    
    if (show) {
        const content = document.getElementById('thinking-content');
        content.textContent = 'Processing your request...';
    }
}

function autoResize() {
    this.style.height = 'auto';
    this.style.height = Math.min(this.scrollHeight, 200) + 'px';
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

async function showTools() {
    const modal = document.getElementById('tools-modal');
    const list = document.getElementById('tools-list');
    
    modal.style.display = 'flex';
    list.innerHTML = 'Loading...';

    try {
        const response = await fetch(`${API_URL}/tools`);
        const data = await response.json();
        
        if (data.tools) {
            list.innerHTML = data.tools.map(tool => `
                <div class="tool-item">
                    <strong>${escapeHtml(tool.name)}</strong>
                    <p>${escapeHtml(tool.description || '')}</p>
                </div>
            `).join('');
        }
    } catch (error) {
        list.innerHTML = `<p class="error">Failed to load tools: ${error.message}</p>`;
    }
}

async function showStatus() {
    const modal = document.getElementById('status-modal');
    const content = document.getElementById('status-content');
    
    modal.style.display = 'flex';
    content.innerHTML = 'Loading...';

    try {
        const response = await fetch(`${API_URL}/status`);
        const data = await response.json();
        
        content.innerHTML = `
            <div class="status-item">
                <strong>Memory:</strong>
                <pre>${JSON.stringify(data.memory, null, 2)}</pre>
            </div>
            <div class="status-item">
                <strong>Sessions:</strong> ${data.sessions}
            </div>
            <div class="status-item">
                <strong>Tools:</strong> ${data.tools}
            </div>
        `;
    } catch (error) {
        content.innerHTML = `<p class="error">Failed to load status: ${error.message}</p>`;
    }
}

function clearConversation() {
    const messages = document.getElementById('messages');
    messages.innerHTML = `
        <div class="message system">
            <div class="message-content">
                Conversation cleared. How can I help you?
            </div>
        </div>
    `;
    currentSessionId = null;
}
"use strict";

const BRIDGE = "http://127.0.0.1:8765";
const BRIDGE_VERSION = "1.5";
const YOUTUBE_MUSIC_TABS = { url: ["https://music.youtube.com/*"] };

async function reconnectYouTubeMusicTabs() {
  const tabs = await chrome.tabs.query(YOUTUBE_MUSIC_TABS);
  await Promise.all(tabs.map((tab) => {
    if (!tab.id) return Promise.resolve();
    return chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["content.js"]
    }).catch(() => null);
  }));
}

function scheduleReconnect() {
  chrome.alarms.create("muusy-reconnect", { periodInMinutes: 0.5 });
  reconnectYouTubeMusicTabs().catch(() => null);
}

chrome.runtime.onInstalled.addListener(scheduleReconnect);
chrome.runtime.onStartup.addListener(scheduleReconnect);
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "muusy-reconnect") reconnectYouTubeMusicTabs().catch(() => null);
});
chrome.tabs.onUpdated.addListener((_tabId, changeInfo, tab) => {
  if (changeInfo.status === "complete" && tab.url?.startsWith("https://music.youtube.com/")) {
    reconnectYouTubeMusicTabs().catch(() => null);
  }
});

async function bridgeFetch(path, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2500);
  try {
    return await fetch(`${BRIDGE}${path}`, {
      ...options,
      headers: {
        "X-YMDI-Bridge": BRIDGE_VERSION,
        ...(options.headers || {})
      },
      signal: controller.signal,
      cache: "no-store"
    });
  } finally {
    clearTimeout(timeout);
  }
}

async function postState(payload) {
  const body = JSON.stringify(payload);
  const response = await bridgeFetch("/state", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-YMDI-Body-Chars": String(body.length)
    },
    body
  });

  if (!response.ok) {
    throw new Error(`Bridge returned ${response.status}`);
  }
}

async function pollCommands(after) {
  const response = await bridgeFetch(`/commands?after=${encodeURIComponent(after || 0)}`);

  if (!response.ok) {
    throw new Error(`Bridge returned ${response.status}`);
  }

  return response.json();
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message.type !== "string") {
    return false;
  }

  if (message.type === "YMDI_STATE") {
    postState(message.payload)
      .then(() => sendResponse({ ok: true }))
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }

  if (message.type === "YMDI_COMMANDS") {
    pollCommands(message.after)
      .then((commands) => sendResponse({ ok: true, commands }))
      .catch((error) => sendResponse({ ok: false, commands: [], error: error.message }));
    return true;
  }

  return false;
});

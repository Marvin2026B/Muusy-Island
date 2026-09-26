(function () {
  "use strict";

  if (window.__MUUSY_ISLAND_BRIDGE_LOADED__) return;
  window.__MUUSY_ISLAND_BRIDGE_LOADED__ = true;

  const BRIDGE_BUILD = "1.5.1";
  let lastCommand = 0;
  const queuePage = [...crypto.getRandomValues(new Uint8Array(8))].map(value => value.toString(16).padStart(2, "0")).join("");
  const queueTokens = new Map();
  let queueSequence = 0;
  let lastStateJson = "";
  let lastPublishAt = 0;
  let tickRunning = false;
  let playerObserver = null;
  let observedPlayer = null;
  let queueObserver = null;
  let observedQueue = null;
  let publishDebounce = 0;

  const clean = (value) => (value || "").replace(/\s+/g, " ").trim();
  const query = (selector, scope = document) => scope?.querySelector(selector) || null;
  function queryDeep(selector, root = document) {
    if (!root) return null;
    const direct = root.querySelector?.(selector);
    if (direct) return direct;
    if (root.shadowRoot) {
      const inRootShadow = queryDeep(selector, root.shadowRoot);
      if (inRootShadow) return inRootShadow;
    }
    const nodes = root.querySelectorAll?.("*") || [];
    for (const node of nodes) {
      if (!node.shadowRoot) continue;
      const match = queryDeep(selector, node.shadowRoot);
      if (match) return match;
    }
    return null;
  }
  function allDeep(selector, root) {
    if (!root) return [];
    const found = [...(root.querySelectorAll?.(selector) || [])];
    if (root.shadowRoot) found.push(...allDeep(selector, root.shadowRoot));
    for (const node of root.querySelectorAll?.("*") || []) {
      if (node.shadowRoot) found.push(...allDeep(selector, node.shadowRoot));
    }
    return found;
  }
  const normalize = (value) =>
    clean(value).toLocaleLowerCase().replace(/[^\p{L}\p{N}]/gu, "");

  function getPlayer() {
    return query("ytmusic-player-bar");
  }

  function getTrack() {
    const metadata = navigator.mediaSession?.metadata;
    const mediaTitle = clean(metadata?.title);
    const mediaArtist = clean(metadata?.artist);
    const mediaCover = Array.isArray(metadata?.artwork)
      ? [...metadata.artwork].reverse().find((art) => /^https?:\/\//i.test(art?.src || ""))?.src || ""
      : "";

    if (mediaTitle && mediaTitle.toLowerCase() !== "youtube music") {
      return {
        title: mediaTitle,
        artist: mediaArtist || clean(metadata?.album) || "YouTube Music",
        cover: mediaCover
      };
    }

    const player = getPlayer();
    if (!player) {
      return { title: "YouTube Music", artist: "Warte auf Wiedergabe", cover: "" };
    }

    const title =
      clean(query("yt-formatted-string.title.ytmusic-player-bar", player)?.textContent) ||
      clean(query(".middle-controls .title", player)?.textContent) ||
      "YouTube Music";
    const rawArtist =
      clean(query("yt-formatted-string.byline.ytmusic-player-bar", player)?.textContent) ||
      clean(query(".middle-controls .byline", player)?.textContent) ||
      "YouTube Music";
    const artist = rawArtist
      .replace(/^[\u2022\u00b7]\s*/, "")
      .split(/[\u2022\u00b7]/)[0]
      .trim() || "YouTube Music";
    const coverCandidates = [
      query("img.image.ytmusic-player-bar", player)?.src,
      query(".thumbnail-image-wrapper img", player)?.src,
      query(".thumbnail img", player)?.src
    ];
    const cover = coverCandidates.find((src) => /^https?:\/\/.+\/.+/i.test(src || "")) || "";
    return { title, artist, cover };
  }

  function getTimes() {
    const video = query("video");
    return {
      current: Number.isFinite(video?.currentTime) ? video.currentTime : 0,
      duration: Number.isFinite(video?.duration) ? video.duration : 0
    };
  }

  function getRatingControl(kind) {
    const player = getPlayer();
    if (!player) return null;
    const rating = queryDeep("ytmusic-like-button-renderer", player) || player;
    const selectors = kind === "like"
      ? ["#like-button", "#button-shape-like button"]
      : ["#dislike-button", "#button-shape-dislike button"];
    for (const selector of selectors) {
      const button = queryDeep(selector, rating);
      if (button) return button;
    }
    const opposite = kind === "like" ? "dislike" : "like";
    const labels = kind === "like"
      ? [/^like(?:\s|$)/i, /^i like this/i, /^gefällt mir$/i, /^mag ich$/i]
      : [/^dislike(?:\s|$)/i, /^i dislike this/i, /^gefällt mir nicht$/i, /^mag ich nicht$/i];
    return allDeep("button, tp-yt-paper-icon-button", rating).find((button) => {
      const label = `${button.getAttribute("aria-label") || ""} ${button.title || ""} ${button.getAttribute("data-tooltip-text") || ""}`.trim();
      const normalized = label.toLocaleLowerCase();
      return !button.disabled && !normalized.includes(opposite) && labels.some((pattern) => pattern.test(label));
    }) || null;
  }

  function getControl(kind) {
    if (kind === "like" || kind === "dislike") return getRatingControl(kind);
    const player = getPlayer();
    if (!player) return null;
    const exactSelectors = {
      play: "#play-pause-button",
      prev: ".previous-button",
      next: ".next-button"
    };
    const exact = query(exactSelectors[kind], player);
    if (exact) return exact;
    const labels = {
      play: ["play", "pause", "abspielen", "pausieren"],
      prev: ["previous", "zur\u00fcck", "vorheriger"],
      next: ["next", "weiter", "n\u00e4chster"]
    }[kind] || [];
    return [...player.querySelectorAll("button, tp-yt-paper-icon-button")].find((button) => {
      const label = `${button.getAttribute("aria-label") || ""} ${button.title || ""}`.toLowerCase();
      return labels.some((candidate) => label.includes(candidate));
    }) || null;
  }

  function isPlaying() {
    const video = query("video");
    if (video) return !video.paused && !video.ended;
    if (navigator.mediaSession?.playbackState) {
      return navigator.mediaSession.playbackState === "playing";
    }
    const button = getControl("play");
    const label = `${button?.getAttribute("aria-label") || ""} ${button?.title || ""}`.toLowerCase();
    return label.includes("pause") || label.includes("pausieren");
  }

  function getRating() {
    const active = (button) =>
      !!button && (
        button.getAttribute("aria-pressed") === "true" ||
        button.getAttribute("aria-checked") === "true" ||
        button.hasAttribute("selected")
      );
    if (active(getRatingControl("like"))) return 1;
    if (active(getRatingControl("dislike"))) return -1;
    return 0;
  }

  function parseQueueRow(row) {
    const title = clean(
      query(".song-title", row)?.textContent ||
      query("yt-formatted-string.song-title", row)?.textContent ||
      query("#video-title", row)?.textContent ||
      query(".title", row)?.textContent
    );
    const rawArtist = clean(
      query(".byline", row)?.textContent ||
      query(".secondary-flex-columns", row)?.textContent ||
      query(".subtitle", row)?.textContent
    );
    return title
      ? { title, artist: rawArtist.split(/[\u2022\u00b7]/)[0].trim() }
      : null;
  }

  function getQueueVideoId(row) {
    const directId = row.getAttribute("video-id") || queryDeep("[video-id]", row)?.getAttribute("video-id");
    if (directId) return directId;
    const link = queryDeep('a[href*="watch?v="]', row);
    if (!link) return "";
    try {
      return new URL(link.href, location.href).searchParams.get("v") || "";
    } catch (_) {
      return "";
    }
  }

  function getQueueEntries() {
    const selector = [
      "ytmusic-player-queue ytmusic-player-queue-item",
      "ytmusic-player-queue ytmusic-playlist-panel-video-renderer",
      "ytmusic-player-queue-item",
      "ytmusic-playlist-panel-video-renderer"
    ].join(",");
    const seen = new Set();
    const rows = [...document.querySelectorAll(selector)].filter((row) => {
      if (seen.has(row)) return false;
      seen.add(row);
      return true;
    });
    const occurrences = new Map();
    const parsed = rows.map(row => {
      const item = parseQueueRow(row);
      if (!item) return null;
      const videoId = getQueueVideoId(row);
      const baseIdentity = videoId
        ? `video:${videoId}`
        : `${normalize(item.title)}\n${normalize(item.artist)}`;
      const occurrence = occurrences.get(baseIdentity) || 0;
      occurrences.set(baseIdentity, occurrence + 1);
      const identity = `${baseIdentity}\n${occurrence}`;
      let token = queueTokens.get(identity);
      if (!token) {
        token = `${queuePage}:${++queueSequence}`;
        queueTokens.set(identity, token);
        if (queueTokens.size > 4096) {
          const oldest = queueTokens.keys().next();
          if (!oldest.done) queueTokens.delete(oldest.value);
        }
      }
      return { ...item, queueToken: token, row };
    }).filter(Boolean);
    if (!parsed.length) return [];
    const currentTitle = normalize(getTrack().title);
    let currentIndex = parsed.findIndex(item => item.row.hasAttribute("selected") || item.row.getAttribute("aria-selected") === "true");
    if (currentIndex < 0) currentIndex = parsed.findIndex(item => normalize(item.title) === currentTitle);
    const candidates = currentIndex >= 0
      ? parsed.slice(currentIndex + 1)
      : parsed.filter((item) => normalize(item.title) !== currentTitle);
    return candidates.slice(0, 3);
  }

  function getQueue() {
    return getQueueEntries().map(({ row, ...item }) => item);
  }

  function activateQueueItem(row) {
    if (!row?.isConnected) return false;
    const playButton = queryDeep("#play-button", row) ||
      allDeep("button, tp-yt-paper-icon-button", row).find(button => {
        const label = `${button.getAttribute("aria-label") || ""} ${button.title || ""}`.toLowerCase();
        return /play|abspielen|wiedergeben/.test(label) &&
          !button.disabled && button.getAttribute("aria-disabled") !== "true";
      });
    const titleControl = queryDeep("#video-title", row) || queryDeep(".song-title", row);
    const control = playButton || titleControl || row;
    if (control.disabled || control.getAttribute?.("aria-disabled") === "true") return false;
    control.click();
    return true;
  }

  async function executeCommand(command) {
    const action = command.action;
    if (action === "queue") {
      if (!/^[a-f0-9]{16}:[1-9][0-9]{0,8}$/.test(command.queueToken || "") ||
          !Number.isFinite(command.expiresAt) || command.expiresAt <= Date.now()) return false;
      if (!command.queueToken.startsWith(`${queuePage}:`)) return false;
      for (let attempt = 0; attempt < 8; attempt++) {
        const item = getQueueEntries().find(entry => entry.queueToken === command.queueToken);
        if (item?.row.isConnected) return activateQueueItem(item.row);
        if (attempt < 7) await new Promise(resolve => window.setTimeout(resolve, 100));
      }
      return false;
    }
    if (!["play", "prev", "next", "like", "dislike"].includes(action)) return false;
    for (let attempt = 0; attempt < 8; attempt++) {
      const control = getControl(action);
      if (control && !control.disabled) {
        control.click();
        return true;
      }
      await new Promise((resolve) => window.setTimeout(resolve, 150));
    }
    return false;
  }

  function sendMessage(message) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage(message, (response) => {
          if (chrome.runtime.lastError) {
            resolve(null);
            return;
          }
          resolve(response || null);
        });
      } catch (_) {
        resolve(null);
      }
    });
  }

  async function publishState(force = false) {
    const now = Date.now();
    const track = getTrack();
    const times = getTimes();
    const payload = {
      title: track.title,
      artist: track.artist,
      cover: track.cover,
      playing: isPlaying(),
      current: times.current,
      duration: times.duration,
      queue: getQueue(),
      queueSelection: true,
      liked: getRating(),
      sourceName: "YouTube Music",
      sourceKey: "youtube",
      bridgeBuild: BRIDGE_BUILD,
      url: location.href,
      at: now
    };
    const comparison = JSON.stringify({ ...payload, current: Math.floor(payload.current), at: 0 });
    const heartbeatDue = now - lastPublishAt >= 5000;
    if (!force && comparison === lastStateJson && !heartbeatDue) return;
    const response = await sendMessage({ type: "YMDI_STATE", payload });
    if (response?.ok) {
      lastStateJson = comparison;
      lastPublishAt = now;
    }
  }

  async function receiveCommands() {
    const response = await sendMessage({ type: "YMDI_COMMANDS", after: lastCommand });
    const commands = Array.isArray(response?.commands) ? response.commands : [];
    for (const command of commands) {
      const completed = await executeCommand(command);
      // A removed/reused row must never play a different song or block subsequent controls.
      if (!completed && command.action !== "queue") break;
      lastCommand = Math.max(lastCommand, Number(command.id) || 0);
    }
    if (commands.length) window.setTimeout(() => publishState(true), 150);
  }

  function scheduleImmediatePublish(delay = 40) {
    window.clearTimeout(publishDebounce);
    publishDebounce = window.setTimeout(() => publishState(true), delay);
  }

  function ensurePlayerObserver() {
    const player = getPlayer();
    if (!player || player === observedPlayer) return;
    playerObserver?.disconnect();
    observedPlayer = player;
    playerObserver = new MutationObserver(() => scheduleImmediatePublish(35));
    playerObserver.observe(player, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["src", "selected", "aria-pressed"]
    });
    scheduleImmediatePublish(0);
  }

  function ensureQueueObserver() {
    const queue = query("ytmusic-player-queue") || query("#queue");
    if (!queue || queue === observedQueue) return;
    queueObserver?.disconnect();
    observedQueue = queue;
    queueObserver = new MutationObserver(() => scheduleImmediatePublish(60));
    queueObserver.observe(queue, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["selected", "aria-selected", "aria-pressed"]
    });
    scheduleImmediatePublish(0);
  }

  function start() {
    publishState(true);
    ensurePlayerObserver();
    ensureQueueObserver();
    window.setInterval(async () => {
      if (tickRunning) return;
      tickRunning = true;
      try {
        ensurePlayerObserver();
        ensureQueueObserver();
        await publishState();
        await receiveCommands();
      } finally {
        tickRunning = false;
      }
    }, 500);
    window.addEventListener("yt-navigate-finish", () => {
      window.setTimeout(() => publishState(true), 250);
    });
    document.addEventListener("play", () => publishState(true), true);
    document.addEventListener("pause", () => publishState(true), true);
    document.addEventListener("loadedmetadata", () => publishState(true), true);
    document.addEventListener("durationchange", () => scheduleImmediatePublish(20), true);
    document.addEventListener("emptied", () => scheduleImmediatePublish(20), true);
    document.addEventListener("visibilitychange", () => publishState(true));
    window.addEventListener("pageshow", () => publishState(true));
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();

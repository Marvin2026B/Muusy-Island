(function () {
  "use strict";

  if (window.__MUUSY_ISLAND_BRIDGE_LOADED__) return;
  window.__MUUSY_ISLAND_BRIDGE_LOADED__ = true;

  let lastCommand = 0;
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
    const rating = query("ytmusic-like-button-renderer", player) || player;
    const selectors = kind === "like"
      ? ["#like-button", "#button-shape-like button", "[aria-label*='like' i]", "[aria-label*='mag ich' i]"]
      : ["#dislike-button", "#button-shape-dislike button", "[aria-label*='dislike' i]", "[aria-label*='mag ich nicht' i]"];
    for (const selector of selectors) {
      const button = query(selector, rating);
      if (button) return button;
    }
    const buttons = [...rating.querySelectorAll("button, tp-yt-paper-icon-button")];
    return kind === "like" ? buttons[0] || null : buttons[1] || null;
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

  function getQueue() {
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
    const parsed = rows.map(parseQueueRow).filter(Boolean);
    if (!parsed.length) return [];
    const currentTitle = normalize(getTrack().title);
    const currentIndex = parsed.findIndex((item) => normalize(item.title) === currentTitle);
    const candidates = currentIndex >= 0
      ? parsed.slice(currentIndex + 1)
      : parsed.filter((item) => normalize(item.title) !== currentTitle);
    return candidates.slice(0, 3);
  }

  function executeCommand(action) {
    getControl(action)?.click();
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
      liked: getRating(),
      sourceName: "YouTube Music",
      sourceKey: "youtube",
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
      lastCommand = Math.max(lastCommand, Number(command.id) || 0);
      executeCommand(command.action);
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

/* =============================================================================
   LMS learning player  (Application static file: player.js, page 200:20)
   STATUS: written, not run in a browser.
   Principle: the browser only REPORTS events. The server (LMS_PROGRESS_PKG via Ajax callback AJAX_PROGRESS) decides
   what counts. Retrying an event re-sends the SAME uuid, so the server de-duplicates it.
   Needs Text Messages (Use in JavaScript = Yes): LMS_JS_SAVED, LMS_JS_OFFLINE, LMS_JS_COMPLETE_FAIL, LMS_JS_LESSON_DONE
   ============================================================================= */
(function (global, $, apex) {
  "use strict";

  var HEARTBEAT_MS = 30000;      // matches PROGRESS_UPDATE policy (30/min) with a wide margin
  var MAX_RETRY = 3;

  var state = { enrollmentId: null, lessonId: null, media: null, timer: null, lastPos: 0,
                lastBeat: Date.now(), pending: null, ajaxName: "AJAX_PROGRESS", completed: false };

  function uuid() {
    if (global.crypto && global.crypto.randomUUID) { return global.crypto.randomUUID(); }
    // RFC 4122 v4 fallback using getRandomValues (never Math.random for identifiers)
    var b = new Uint8Array(16); global.crypto.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    var h = Array.prototype.map.call(b, function (x) { return ("0" + x.toString(16)).slice(-2); }).join("");
    return h.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, "$1-$2-$3-$4-$5");
  }

  function msg(key, fallback) {
    var t = apex.lang && apex.lang.getMessage ? apex.lang.getMessage(key) : null;
    return (t && t !== key) ? t : fallback;
  }

  function announce(text) {
    var live = document.getElementById("lms-live");           // <div id="lms-live" aria-live="polite" class="u-VisuallyHidden">
    if (live) { live.textContent = text; }
  }

  function setProgress(pct) {
    var bar = document.querySelector("#lms-progress > span");
    var wrap = document.getElementById("lms-progress");
    if (bar) { bar.style.inlineSize = pct + "%"; }
    if (wrap) {
      wrap.setAttribute("aria-valuenow", Math.round(pct));
      wrap.classList.toggle("lms-progress--done", pct >= 100);
    }
    if (apex.item("P20_PROGRESS").node) { apex.item("P20_PROGRESS").setValue(pct, null, true); }
  }

  /* Sends one event. Resolves with the server answer; on network failure retries with the SAME uuid. */
  function send(eventType, seconds, attempt) {
    var id = (attempt && state.pending) ? state.pending : uuid();
    state.pending = id;
    return apex.server.process(state.ajaxName, {
      x01: state.enrollmentId, x02: state.lessonId, x03: eventType, x04: id,
      x05: Math.floor(state.lastPos || 0), x06: Math.max(0, Math.floor(seconds || 0))
    }, { dataType: "json", loadingIndicator: eventType === "COMPLETE" ? "#lms-complete-btn" : null })
    .then(function (res) {
      state.pending = null;
      if (!res || res.ok !== true) {
        var e = new Error((res && res.message) || "error"); e.business = true; throw e;   // server said no: do not retry
      }
      return res;
    })
    .catch(function (err) {
      if (err && err.business) { throw err; }
      if ((attempt || 0) < MAX_RETRY) {
        return new Promise(function (r) { setTimeout(r, 1000 * Math.pow(2, attempt || 0)); })
          .then(function () { return send(eventType, seconds, (attempt || 0) + 1); });
      }
      announce(msg("LMS_JS_OFFLINE", "Connection problem. Your progress will be saved when you are back online."));
      throw err;
    });
  }

  function heartbeat() {
    if (document.visibilityState !== "visible" || state.completed) { return; }
    var m = state.media;
    if (m && (m.paused || m.ended)) { return; }               // only count time while content is actually playing
    var now = Date.now();
    var secs = Math.min(120, (now - state.lastBeat) / 1000);
    state.lastBeat = now;
    if (m) { state.lastPos = m.currentTime; }
    send("HEARTBEAT", secs, 0).catch(function () { /* already announced */ });
  }

  function onComplete() {
    if (state.completed) { return $.Deferred().resolve().promise(); }
    var secs = Math.min(120, (Date.now() - state.lastBeat) / 1000);
    state.lastBeat = Date.now();
    return send("COMPLETE", secs, 0).then(function (res) {
      state.completed = true;
      setProgress(res.percent);
      announce(msg("LMS_JS_LESSON_DONE", "Lesson completed."));
      var done = document.querySelector('.lms-lesson[aria-current="true"] .lms-lesson__state');
      if (done) { done.textContent = "✓"; }
      apex.event.trigger(document, "lms-lesson-completed", res);   // dynamic action "Custom event" can enable Next / refresh curriculum
      return res;
    }).catch(function (err) {
      apex.message.clearErrors();
      apex.message.showErrors([{ type: "error", location: "page", message: err.message || msg("LMS_JS_COMPLETE_FAIL", "Could not complete the lesson."), unsafe: false }]);
    });
  }

  global.lmsPlayer = {
    /* cfg: { enrollmentId, lessonId, startPosition, completed, ajaxName, media: element|selector } */
    init: function (cfg) {
      state.enrollmentId = cfg.enrollmentId; state.lessonId = cfg.lessonId;
      state.completed = !!cfg.completed; state.lastPos = cfg.startPosition || 0;
      state.ajaxName = cfg.ajaxName || state.ajaxName; state.lastBeat = Date.now();
      state.media = typeof cfg.media === "string" ? document.querySelector(cfg.media) : (cfg.media || null);

      if (state.media && state.lastPos > 0) {
        state.media.addEventListener("loadedmetadata", function () { state.media.currentTime = state.lastPos; }, { once: true });
      }
      if (state.timer) { clearInterval(state.timer); }
      state.timer = setInterval(heartbeat, HEARTBEAT_MS);
      document.addEventListener("visibilitychange", function () {
        if (document.visibilityState === "hidden") { heartbeat(); } else { state.lastBeat = Date.now(); }
      });
      if (!state.completed) { send("START", 0, 0).catch(function () { /* announced */ }); }
      var btn = document.getElementById("lms-complete-btn");
      if (btn) { btn.addEventListener("click", function (e) { e.preventDefault(); onComplete(); }); }
      global.addEventListener("pagehide", function () {          // best effort position save; server de-duplicates retries
        if (!state.completed && state.media) { state.lastPos = state.media.currentTime; }
      });
    },
    complete: onComplete,
    destroy: function () { if (state.timer) { clearInterval(state.timer); state.timer = null; } }
  };
})(window, apex.jQuery, apex);

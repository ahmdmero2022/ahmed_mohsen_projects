/* =============================================================================
   LMS assessment helper  (Application static file: assessment.js, page 200:40)
   STATUS: written, not run in a browser.
   The timer is COSMETIC. The server owns the deadline (LMS_QUIZ_ATTEMPTS.DEADLINE_AT) and rejects answers after it.
   The page hands over server time so a wrong client clock cannot hide or fake the remaining time.
   Text Messages (Use in JavaScript = Yes): LMS_JS_SAVED, LMS_JS_SAVE_FAIL, LMS_JS_TIME_UP, LMS_JS_5MIN, LMS_JS_1MIN
   ============================================================================= */
(function (global, $, apex) {
  "use strict";

  var s = { attemptId: null, deadline: null, skew: 0, timer: null, warned5: false, warned1: false, saveTimer: null, submitted: false };

  function msg(key, fallback) {
    var t = apex.lang && apex.lang.getMessage ? apex.lang.getMessage(key) : null;
    return (t && t !== key) ? t : fallback;
  }
  function announce(text) { var el = document.getElementById("lms-live"); if (el) { el.textContent = text; } }
  function pad(n) { return (n < 10 ? "0" : "") + n; }

  function tick() {
    var el = document.getElementById("lms-timer");
    var left = Math.max(0, Math.round((s.deadline - (Date.now() + s.skew)) / 1000));
    if (el) {
      el.textContent = pad(Math.floor(left / 60)) + ":" + pad(left % 60);
      el.classList.toggle("lms-timer--warn", left <= 300 && left > 60);
      el.classList.toggle("lms-timer--bad", left <= 60);
    }
    if (left <= 300 && !s.warned5) { s.warned5 = true; announce(msg("LMS_JS_5MIN", "5 minutes remaining.")); }
    if (left <= 60 && !s.warned1)  { s.warned1 = true; announce(msg("LMS_JS_1MIN", "1 minute remaining.")); }
    if (left === 0 && !s.submitted) { timeUp(); }
  }

  function timeUp() {
    s.submitted = true;
    clearInterval(s.timer);
    announce(msg("LMS_JS_TIME_UP", "Time is up. Submitting your answers."));
    $(":input", "#lms-question").prop("disabled", true);
    apex.page.submit({ request: "SUBMIT_ATTEMPT", showWait: true });   // server grades the answers saved before the deadline
  }

  /* Builds the JSON the server expects from the DOM of the current question. */
  function collect(root) {
    var $q = $(root || "#lms-question");
    var type = $q.attr("data-type");
    if (type === "MCQ" || type === "TF" || type === "MULTI") {
      var ids = $q.find("input[type=radio]:checked, input[type=checkbox]:checked").map(function () { return Number(this.value); }).get();
      return JSON.stringify({ selected: ids });
    }
    if (type === "MATCH") {
      var pairs = $q.find("select[data-option]").map(function () { return { option: Number($(this).attr("data-option")), choice: $(this).val() }; }).get()
                    .filter(function (p) { return p.choice; });
      return JSON.stringify({ pairs: pairs });
    }
    return JSON.stringify({ text: ($q.find("textarea, input[type=text]").first().val() || "").slice(0, 3500) });
  }

  function save() {
    var $q = $("#lms-question");
    var qid = Number($q.attr("data-question"));
    if (!qid || s.submitted) { return $.Deferred().resolve().promise(); }
    return apex.server.process("AJAX_SAVE_ANSWER", { x01: s.attemptId, x02: qid, x03: collect($q) }, { dataType: "json" })
      .then(function (res) {
        var st = document.getElementById("lms-saved");
        if (res && res.ok) { if (st) { st.textContent = msg("LMS_JS_SAVED", "Saved"); } }
        else { throw new Error((res && res.message) || "save"); }
      })
      .catch(function (e) {
        apex.message.clearErrors();
        apex.message.showErrors([{ type: "error", location: "page", message: e.message || msg("LMS_JS_SAVE_FAIL", "Could not save your answer."), unsafe: false }]);
      });
  }

  global.lmsAssessment = {
    /* cfg: { attemptId, deadlineMs (epoch ms, from the server) | null for untimed, serverNowMs (epoch ms at render) } */
    init: function (cfg) {
      s.attemptId = cfg.attemptId;
      s.skew = (cfg.serverNowMs || Date.now()) - Date.now();          // server clock minus client clock
      if (cfg.deadlineMs) {
        s.deadline = cfg.deadlineMs; tick(); s.timer = setInterval(tick, 1000);
      }
      // autosave 600 ms after the learner stops changing the answer
      $(document).on("change input", "#lms-question :input", function () {
        var st = document.getElementById("lms-saved"); if (st) { st.textContent = ""; }
        clearTimeout(s.saveTimer); s.saveTimer = setTimeout(save, 600);
      });
    },
    save: save,
    /* Previous / Next / Submit buttons use a Dynamic Action (Execute JavaScript):
         lmsAssessment.go('NEXT');   // saves the current answer first, then submits the page request */
    go: function (request) { save().always(function () { apex.page.submit({ request: request, showWait: true }); }); },
    /* the confirmation dialog calls this when the learner confirms the final submit */
    markSubmitting: function () { s.submitted = true; clearInterval(s.timer); }
  };
})(window, apex.jQuery, apex);

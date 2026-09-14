"use strict";

/**
 * @fileoverview The i18n (EN/FR) message table for push notifications plus the
 * pure `build*Message` helpers that consume it. Split out of
 * `notification_utils.js` to keep that module focused on the diff/ledger/send
 * pipeline. Depends only on `time_utils` (locale-aware formatting) and
 * `day_slice_utils` (the run's last work day), both of which are leaves, so it
 * closes no require cycle — nothing here requires back into
 * `notification_utils`.
 * @module notification_messages
 */

const {
  formatBusinessTime,
  formatTimeOfDay,
  businessMinutesOfDay,
  toMillis,
} = require("./time_utils");
const {
  clampedLastWorkDayMs,
  calendarDaysBetween,
} = require("./day_slice_utils");
// `_who` lives in job_naming so the Lock Screen card and the push beside it
// cannot come to call the same job two different things.
const {whoFor: _who} = require("./job_naming");

/**
 * Localized "Wed, Jul 8, 2:00 p.m." style datetime.
 * @param {string} locale
 * @param {*} startTime
 * @param {boolean=} allDay
 * @return {string}
 */
function _dateTime(locale, startTime, allDay) {
  const time = allDay ? {} : {hour: "numeric", minute: "2-digit"};
  return formatBusinessTime(locale, startTime, {
    weekday: "short",
    month: "short",
    day: "numeric",
    ...time,
  });
}

/**
 * Localized time only, or the all-day phrase in place of a clock time.
 * @param {string} locale
 * @param {*} startTime
 * @param {boolean=} allDay
 * @return {string}
 */
function _timeOnly(locale, startTime, allDay) {
  if (allDay) return locale === "fr" ? "toute la journée" : "all day";
  return formatTimeOfDay(locale, startTime);
}

/**
 * Localized recurrence phrase ("every 6 months"/"aux 6 mois") for a
 * RepeatInterval raw value, mirroring RepeatInterval.raw
 * (repeat_interval.dart).
 * @param {string} raw
 * @param {string} locale 'en' | 'fr'.
 * @return {string}
 */
function _repeatLabel(raw, locale) {
  const fr = locale === "fr";
  switch (String(raw || "").toLowerCase()) {
    case "four_months": return fr ? "aux 4 mois" : "every 4 months";
    case "six_months": return fr ? "aux 6 mois" : "every 6 months";
    case "one_year": return fr ? "chaque année" : "every year";
    default: return "";
  }
}

/**
 * `_dateTime` for a message context — all-day and multi-day aware.
 * @param {string} locale
 * @param {!Object} c
 * @return {string}
 */
function _when(locale, c) {
  const base = _dateTime(locale, c.startTime, c.isAllDay === true);
  const last = clampedLastWorkDayMs(c);
  const startMs = toMillis(c.startTime);
  if (last == null || startMs == null) return base;
  if (calendarDaysBetween(startMs, last) < 1) return base;
  return `${base} – ${_dateTime(locale, last, true)}`;
}

/**
 * `_timeOnly` for a message context — all-day aware.
 * @param {string} locale
 * @param {!Object} c
 * @return {string}
 */
function _at(locale, c) {
  return _timeOnly(locale, c.startTime, c.isAllDay === true);
}

/**
 * "Marchetti at 2:00 p.m." / "Dentist · all day" — an all-day block has no
 * clock time to sit after "at", so it joins with a separator instead.
 * @param {string} locale
 * @param {!Object} c
 * @param {string} who
 * @return {string}
 */
function _whoAt(locale, c, who) {
  const time = _at(locale, c);
  if (c.isAllDay === true) return `${who} · ${time}`;
  return locale === "fr" ? `${who} à ${time}` : `${who} at ${time}`;
}

const _MESSAGES = {
  en: {
    who: (c) => _who(c, "Client"),
    assigned: (c, who) => {
      const repeat = _repeatLabel(c.repeat, "en");
      return repeat ? {
        title: "New repeating job assigned",
        body: `${who} · ${_when("en", c)} · repeats ${repeat}`,
      } : {
        title: "New job assigned",
        body: `${who} · ${_when("en", c)}`,
      };
    },
    rescheduled: (c, who) => ({
      title: "Job rescheduled",
      body: `${who} · now ${_when("en", c)}`,
    }),
    cancelled: (c, who) => ({
      title: "Job cancelled",
      body: `${who} · ${_when("en", c)}`,
    }),
    removed: (c, who) => ({
      title: "Removed from a job",
      body: `${who} · ${_when("en", c)}`,
    }),
    reminder: (c, who) => {
      const addr = (c.address || "").trim();
      const base = _whoAt("en", c, who);
      return {
        title: "Upcoming job",
        body: addr ? `${base} · ${addr}` : base,
      };
    },
    leaveNow: (c, who) => {
      const addr = (c.address || "").trim();
      const drive = `About ${c.travelMinutes} min drive`;
      return {
        title: `Time to leave — ${_whoAt("en", c, who)}`,
        body: addr ? `${drive} · ${addr}` : drive,
      };
    },
    doneCheck: (c, who) => ({
      title: "Job finished?",
      body: `Is the job for ${who} done yet? Open the app to update its ` +
          "status.",
    }),
  },
  fr: {
    who: (c) => _who(c, "un client"),
    assigned: (c, who) => {
      const repeat = _repeatLabel(c.repeat, "fr");
      return repeat ? {
        title: "Nouvelle visite récurrente",
        body: `${who} · ${_when("fr", c)} · se répète ${repeat}`,
      } : {
        title: "Nouvelle visite assignée",
        body: `${who} · ${_when("fr", c)}`,
      };
    },
    rescheduled: (c, who) => ({
      title: "Visite reportée",
      body: `${who} · maintenant ${_when("fr", c)}`,
    }),
    cancelled: (c, who) => ({
      title: "Visite annulée",
      body: `${who} · ${_when("fr", c)}`,
    }),
    removed: (c, who) => ({
      title: "Retiré d'une visite",
      body: `${who} · ${_when("fr", c)}`,
    }),
    reminder: (c, who) => {
      const addr = (c.address || "").trim();
      const base = _whoAt("fr", c, who);
      return {
        title: "Visite à venir",
        body: addr ? `${base} · ${addr}` : base,
      };
    },
    leaveNow: (c, who) => {
      const addr = (c.address || "").trim();
      const drive = `Environ ${c.travelMinutes} min de route`;
      return {
        title: "C'est l'heure de partir — " +
            `${_whoAt("fr", c, who)}`,
        body: addr ? `${drive} · ${addr}` : drive,
      };
    },
    doneCheck: (c, who) => ({
      title: "Travail terminé ?",
      body: `Le travail pour ${who} est-il terminé ? ` +
          "Ouvrez l'application pour mettre à jour son statut.",
    }),
  },
};

/**
 * Builds a localized {title, body} for a per-appointment notification.
 * @param {string} kind
 * assigned|rescheduled|cancelled|removed|reminder|doneCheck.
 * @param {{clientName: string, startTime: *, address: string}} ctx
 * @param {string} locale 'en' | 'fr'.
 * @return {{title: string, body: string}}
 */
function buildNotificationMessage(kind, ctx, locale) {
  const table = _MESSAGES[locale === "fr" ? "fr" : "en"];
  const build = table[kind];
  if (!build) return {title: "", body: ""};
  const c = ctx || {};
  return build(c, table.who(c));
}

/**
 * Builds the nightly-digest {title, body}.
 * @param {!Array<!Object>} jobs Tomorrow's jobs for one employee.
 * @param {string} locale 'en' | 'fr'.
 * @return {{title: string, body: string}}
 */
function buildDigestMessage(jobs, locale) {
  const fr = locale === "fr";
  // Clock time, matching groupTomorrowsJobsByEmployee — see the note there.
  const sorted = [...(jobs || [])].sort(
      (a, b) =>
        (businessMinutesOfDay(a.startTime) ?? 0) -
      (businessMinutesOfDay(b.startTime) ?? 0),
  );
  const n = sorted.length;
  const first = sorted[0];
  const loc = fr ? "fr" : "en";
  const lead = first ?
      _whoAt(loc, first, _who(first, fr ? "un client" : "Client")) : "";
  if (fr) {
    const noun = n === 1 ? "visite" : "visites";
    return {
      title: "Votre horaire de demain",
      body: first ?
        `Vous avez ${n} ${noun} demain. Première : ${lead}.` :
        "Vous avez des visites demain.",
    };
  }
  const noun = n === 1 ? "job" : "jobs";
  return {
    title: "Tomorrow's schedule",
    body: first ?
      `You have ${n} ${noun} tomorrow. First: ${lead}.` :
      "You have jobs tomorrow.",
  };
}

/**
 * Builds the "an admin changed your sign-in email" {title, body}.
 * @param {string} email The new sign-in email.
 * @param {string} locale 'en' | 'fr'.
 * @return {{title: string, body: string}}
 */
function buildEmailChangedMessage(email, locale) {
  const address = String(email || "").trim();
  if (locale === "fr") {
    return {
      title: "Courriel de connexion modifié",
      body: address ?
        `Utilisez ${address} pour vous connecter dorénavant.` :
        "Votre adresse de connexion a changé. Contactez votre gestionnaire.",
    };
  }
  return {
    title: "Sign-in email changed",
    body: address ?
      `Use ${address} to sign in from now on.` :
      "Your sign-in address changed. Check with your manager.",
  };
}

/**
 * Tells an ADMIN that a team member moved their OWN sign-in address.
 * @param {string} name The person's display name.
 * @param {string} locale 'en' or 'fr'.
 * @return {{title: string, body: string}}
 */
function buildSelfEmailChangedMessage(name, locale) {
  const who = String(name || "").trim();
  if (locale === "fr") {
    return {
      title: "Courriel de connexion modifié",
      body: who ?
        `${who} a modifié son adresse de connexion.` :
        "Un membre de l'équipe a modifié son adresse de connexion.",
    };
  }
  return {
    title: "Sign-in email changed",
    body: who ?
      `${who} changed their sign-in address.` :
      "A team member changed their sign-in address.",
  };
}

/**
 * "Marc finished Leak fix" — the completion notice the dispatcher gets.
 * @param {string} who The crew member's display name.
 * @param {string} what The job's client name or title.
 * @param {string} locale 'en' or 'fr'.
 * @return {{title: string, body: string}}
 */
function buildJobCompletedMessage(who, what, locale) {
  const crew = String(who || "").trim();
  const job = String(what || "").trim();
  if (locale === "fr") {
    return {
      title: "Travail terminé",
      body: crew && job ?
        `${crew} a terminé ${job}.` :
        (job ? `${job} est terminé.` : "Un travail a été terminé."),
    };
  }
  return {
    title: "Job finished",
    body: crew && job ?
      `${crew} finished ${job}.` :
      (job ? `${job} was marked complete.` : "A job was marked complete."),
  };
}

/**
 * The month-end "N jobs still open" push the admin gets.
 * @param {number} count Open overdue jobs.
 * @param {boolean} capped Whether the scan hit its ceiling.
 * @param {(Date|number)} now Names the month that is wrapping up.
 * @param {string} locale 'en' or 'fr'.
 * @return {{title: string, body: string}}
 */
function buildOverdueReviewMessage(count, capped, now, locale) {
  const n = capped ? `${count}+` : String(count);
  const one = !capped && count === 1;
  if (locale === "fr") {
    const month = formatBusinessTime("fr", now, {month: "long"});
    const de = /^[aeiouh]/i.test(month) ? "d'" : "de ";
    return {
      title: one ? `${n} visite encore ouverte` :
        `${n} visites encore ouvertes`,
      body: one ?
        "Elle s'est terminée sans être fermée. " +
          `Passez-la en revue avant la fin ${de}${month}.` :
        "Elles se sont terminées sans être fermées. " +
          `Passez-les en revue avant la fin ${de}${month}.`,
    };
  }
  const month = formatBusinessTime("en", now, {month: "long"});
  return {
    title: one ? `${n} job still open` : `${n} jobs still open`,
    body: one ?
      `It ended without being closed. Review it before ${month} wraps up.` :
      "They ended without being closed. " +
        `Review them before ${month} wraps up.`,
  };
}

module.exports = {
  buildOverdueReviewMessage,
  buildNotificationMessage,
  buildDigestMessage,
  buildEmailChangedMessage,
  buildSelfEmailChangedMessage,
  buildJobCompletedMessage,
};

// CalendarRoster.js — JavaScript for Automation used by Roster via
// `osascript -l JavaScript CalendarRoster.js <payload-JSON>`.
//
// Reads/mutates attendees only through Calendar.app scripting. Add-only:
// attendees are appended, never removed or modified, and no RSVP is made.
// The fast preview path lives in the app (EventKit); this script still backs
// the preview when EventKit cannot read the attendee list, and always backs
// the write, so its reads are batched: candidate properties arrive in one
// Apple event and attendee emails in one Apple event, with per-object reads
// kept only as fallbacks.
// Identity rule (amended): Calendar's scripting calendarIdentifier proved
// unreadable on current macOS builds and scripting uids do not equal any
// EventKit identifier, so the event is matched conservatively by
//   writable calendar with exactly the payload calendar title (exactly one)
//   + exact title + exact start/end instants (Y/M-D for all-day)
//   + all-day flag,
// and for a recurring-series target the unique recurring master with the same
// title and wall-clock time whose anchor precedes the occurrence. Anything
// ambiguous fails closed; the user confirms title and date in the review
// dialog before any write.
//
// The helpers below the first banner are pure and are also exercised by unit
// tests through JavaScriptCore; `run` defers Application("Calendar") creation
// so the helpers can be loaded without touching live Calendar data.

var IDENTITY_MISMATCH_MESSAGE = "Cannot safely match this event in Calendar; no invitees were added";
var UNCONFIRMED_MESSAGE = "Calendar did not confirm the update. Check the event before trying again.";

// ---- Pure helpers -------------------------------------------------------

function normalizeEmail(value) {
    if (typeof value !== "string") return null;
    var s = value.trim().toLowerCase();
    if (s.indexOf("mailto:") === 0) s = s.slice(7);
    s = s.trim();
    return s.length === 0 ? null : s;
}

// Required emails minus already-present attendee emails. Comparison is
// trimmed/lowercased with any "mailto:" prefix stripped; output keeps the
// required order and deduplicates by normalized key.
function missingEmailKeys(requiredEmails, attendeeEmails) {
    var attendeeKeys = {};
    (attendeeEmails || []).forEach(function (email) {
        var key = normalizeEmail(email);
        if (key) attendeeKeys[key] = true;
    });
    var seen = {};
    var missing = [];
    (requiredEmails || []).forEach(function (email) {
        var key = normalizeEmail(email);
        if (!key || seen[key]) return;
        seen[key] = true;
        if (!attendeeKeys[key]) missing.push(key);
    });
    return missing;
}

// The review must still be true before any write: same missing set and same
// whole-series scope. Set equality, not order, so a roster reorder between
// preview and apply does not force a pointless re-review.
function reviewMatches(previousKeys, currentKeys, previousIsSeries, currentIsSeries) {
    if (previousIsSeries !== currentIsSeries) return false;
    function toSet(keys) {
        var set = {};
        (keys || []).forEach(function (key) {
            var normalized = normalizeEmail(key);
            if (normalized) set[normalized] = true;
        });
        return set;
    }
    var previous = toSet(previousKeys);
    var current = toSet(currentKeys);
    var previousList = Object.keys(previous);
    var currentList = Object.keys(current);
    if (previousList.length !== currentList.length) return false;
    for (var i = 0; i < previousList.length; i++) {
        if (!current[previousList[i]]) return false;
    }
    return true;
}

function sameYMD(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function sameHMS(a, b) {
    return a.getHours() === b.getHours() && a.getMinutes() === b.getMinutes() && a.getSeconds() === b.getSeconds();
}

// A candidate meta is plain data read from one scripting event:
// { summary, allDay, start: Date, end: Date, hasRecurrence }.
// Returns the indices of all candidates matching the payload identity.
// The caller must require exactly one match; anything else fails closed.
function matchCandidates(candidates, payload) {
    var payloadStart = new Date(payload.startDate);
    var payloadEnd = new Date(payload.endDate);
    var matches = [];
    (candidates || []).forEach(function (candidate, index) {
        if (candidate.summary !== payload.title) return;
        if (candidate.allDay !== payload.isAllDay) return;
        if (payload.isSeries) {
            // Occurrence → unique recurring master: same title, same
            // wall-clock time of day, anchor at or before the occurrence.
            if (!candidate.hasRecurrence) return;
            if (candidate.start.getTime() > payloadStart.getTime()) return;
            if (!sameHMS(candidate.start, payloadStart)) return;
        } else if (payload.isAllDay) {
            if (!sameYMD(candidate.start, payloadStart)) return;
            if (!sameYMD(candidate.end, payloadEnd)) return;
        } else {
            if (candidate.start.getTime() !== payloadStart.getTime()) return;
            if (candidate.end.getTime() !== payloadEnd.getTime()) return;
        }
        matches.push(index);
    });
    return matches;
}

// ---- Payload -----------------------------------------------------------

function validatePayload(payload) {
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        throw new Error("Invalid payload: expected an object");
    }
    if (payload.mode !== "preview" && payload.mode !== "apply" && payload.mode !== "locate") {
        throw new Error("Invalid payload: mode must be preview, apply, or locate");
    }
    ["calendarTitle", "title", "startDate", "endDate"].forEach(function (key) {
        if (typeof payload[key] !== "string" || payload[key].length === 0) {
            throw new Error("Invalid payload: " + key + " must be a nonempty string");
        }
    });
    if (typeof payload.isAllDay !== "boolean" || typeof payload.isSeries !== "boolean") {
        throw new Error("Invalid payload: isAllDay and isSeries must be booleans");
    }
    if (!Array.isArray(payload.requiredEmails)) {
        throw new Error("Invalid payload: requiredEmails must be an array");
    }
    payload.requiredEmails.forEach(function (email) {
        if (typeof email !== "string" || normalizeEmail(email) === null) {
            throw new Error("Invalid payload: every requiredEmail must be a nonempty string");
        }
    });
    if (!Array.isArray(payload.reviewedMissingKeys)) {
        throw new Error("Invalid payload: reviewedMissingKeys must be an array");
    }
    payload.reviewedMissingKeys.forEach(function (key) {
        if (typeof key !== "string" || normalizeEmail(key) === null) {
            throw new Error("Invalid payload: reviewedMissingKeys entries must be nonempty strings");
        }
    });
    if (isNaN(new Date(payload.startDate).getTime()) || isNaN(new Date(payload.endDate).getTime())) {
        throw new Error("Invalid payload: startDate/endDate must be ISO-8601");
    }
    if (typeof payload.knownUID !== "undefined" && typeof payload.knownUID !== "string") {
        throw new Error("Invalid payload: knownUID must be a string");
    }
}

// ---- Calendar access ----------------------------------------------------

// Exactly one writable calendar with exactly the payload calendar title.
// Names arrive in one Apple event; only same-named candidates (rarely more
// than one) pay a per-calendar writable check.
function findCalendar(Calendar, payload) {
    var matches = [];
    var names = null;
    try { names = Calendar.calendars.name(); } catch (e) { names = null; }
    if (names) {
        for (var i = 0; i < names.length; i++) {
            if (names[i] !== payload.calendarTitle) continue;
            var writable = null;
            try { writable = Calendar.calendars[i].writable(); } catch (e2) { writable = null; }
            if (writable === true) matches.push(Calendar.calendars[i]);
        }
    } else {
        var all = Calendar.calendars();
        for (var j = 0; j < all.length; j++) {
            var name = null;
            var writable2 = null;
            try { name = all[j].name(); } catch (e3) { continue; }
            try { writable2 = all[j].writable(); } catch (e4) { writable2 = null; }
            if (name === payload.calendarTitle && writable2 === true) matches.push(all[j]);
        }
    }
    if (matches.length !== 1) throw new Error(IDENTITY_MISMATCH_MESSAGE);
    return matches[0];
}

// Plain-data meta from one event's properties record. Shared by the bulk
// fast path (properties fetched in one Apple event) and the per-candidate
// fallback.
function metaFromProperties(properties) {
    if (!properties) return null;
    var start = properties.startDate;
    var end = properties.endDate;
    if (!(start instanceof Date) || !(end instanceof Date)) return null;
    var recurrence = properties.recurrence;
    return {
        summary: properties.summary,
        allDay: properties.alldayEvent === true,
        start: start,
        end: end,
        hasRecurrence: typeof recurrence === "string" && recurrence.length > 0
    };
}

// Plain-data meta for one scripting event; read once per candidate.
function candidateMeta(event) {
    var properties = null;
    try { properties = event.properties(); } catch (e) { properties = null; }
    if (properties === null) return null;
    return metaFromProperties(properties);
}

// Exactly one event in the calendar matching the payload identity.
//
// Fast path: `knownUID` was captured by a read-only locate run earlier in
// this flow. byId resolves in milliseconds while a whose scan costs
// seconds-to-minutes on large calendars, so apply should almost always take
// the fast path. The identity check still runs on the byId-resolved event,
// so a stale or wrong uid can only cost the fallback scan — never a wrong
// write.
//
// Non-series payloads match by exact instants, so the scan can be
// date-windowed server-side: Calendar returns a handful of candidates even
// in a calendar with years of history. Calendar's whose evaluator rejects
// _greaterThanOrEquals/_lessThanOrEquals on dates (-1726) but accepts strict
// _greaterThan/_lessThan, so the bounds are widened instead. Series targets
// are recurring masters whose anchor can be arbitrarily old — those keep the
// title-only scan.
function findEvent(calendar, payload) {
    if (typeof payload.knownUID === "string" && payload.knownUID.length > 0) {
        var cached = null;
        try { cached = calendar.events.byId(payload.knownUID); } catch (e) { cached = null; }
        if (cached) {
            var cachedMeta = null;
            try { cachedMeta = candidateMeta(cached); } catch (e2) { cachedMeta = null; }
            if (cachedMeta !== null && matchCandidates([cachedMeta], payload).length === 1) {
                return cached;
            }
        }
        // Stale or wrong uid: fall through to the full conservative match.
    }

    var conditions = [{ summary: { _equals: payload.title } }];
    if (!payload.isSeries) {
        var payloadStart = new Date(payload.startDate);
        var lo = new Date(payloadStart.getTime() - 3 * 86400000);
        var hi = new Date(payloadStart.getTime() + 3 * 86400000);
        conditions.push({ startDate: { _greaterThan: lo } });
        conditions.push({ startDate: { _lessThan: hi } });
    }
    var candidates;
    try {
        candidates = calendar.events.whose({ _and: conditions })();
    } catch (e3) {
        try {
            candidates = calendar.events.whose({ summary: { _equals: payload.title } })();
        } catch (e4) {
            candidates = calendar.events();
        }
    }
    var metas = [];
    var events = [];
    for (var i = 0; i < candidates.length; i++) {
        var meta = candidateMeta(candidates[i]);
        if (meta !== null) {
            metas.push(meta);
            events.push(candidates[i]);
        }
    }
    var matches = matchCandidates(metas, payload);
    if (matches.length !== 1) throw new Error(IDENTITY_MISMATCH_MESSAGE);
    return events[matches[0]];
}

function seriesFlag(event) {
    var recurrence = null;
    try { recurrence = event.recurrence(); } catch (e) { recurrence = null; }
    return typeof recurrence === "string" && recurrence.length > 0;
}

// Reading attendees must succeed or everything fails: a read failure is never
// treated as "no attendees". Fast path asks for every attendee's email in one
// Apple event; per-attendee reads remain as the fallback.
function readAttendeeEmails(event) {
    var bulk = null;
    try { bulk = event.attendees.email()(); } catch (e) { bulk = null; }
    if (bulk) {
        var emails = [];
        for (var i = 0; i < bulk.length; i++) {
            emails.push(bulk[i] == null ? "" : String(bulk[i]));
        }
        return emails;
    }
    var attendees = event.attendees();
    var fallback = [];
    if (attendees) {
        for (var j = 0; j < attendees.length; j++) {
            var email = attendees[j].email();
            fallback.push(email == null ? "" : String(email));
        }
    }
    return fallback;
}

function output(status, fields) {
    var result = {
        status: status,
        attendeeEmails: fields.attendeeEmails || [],
        missingKeys: fields.missingKeys || [],
        isSeries: fields.isSeries === true,
        addedEmails: fields.addedEmails || [],
        remainingEmails: fields.remainingEmails || [],
        warning: fields.warning === undefined ? null : fields.warning,
        message: fields.message === undefined ? null : fields.message,
        uid: fields.uid || ""
    };
    return JSON.stringify(result);
}

// ---- Entry point --------------------------------------------------------

function run(argv) {
    try {
        var payload = JSON.parse(argv[0]);
        validatePayload(payload);

        // Deferred so pure helpers above can be exercised without Calendar.
        var Calendar = Application("Calendar");

        var calendar = findCalendar(Calendar, payload);
        var event = findEvent(calendar, payload);

        var isSeries = seriesFlag(event);

        // Locate is a read-only identity resolution for the app's fast apply:
        // the matched event's scripting uid, so a later apply can resolve it
        // with byId instead of rescanning. No attendees are read here.
        if (payload.mode === "locate") {
            var uid = null;
            try { uid = event.uid(); } catch (e0) { uid = null; }
            return output("located", { uid: uid == null ? "" : String(uid), isSeries: isSeries });
        }

        var attendeeEmails = readAttendeeEmails(event);
        var missing = missingEmailKeys(payload.requiredEmails, attendeeEmails);

        if (payload.mode === "preview") {
            return output("preview", {
                attendeeEmails: attendeeEmails,
                missingKeys: missing,
                isSeries: isSeries
            });
        }

        // Apply: the review must still hold before anything is written.
        if (!reviewMatches(payload.reviewedMissingKeys, missing, payload.isSeries, isSeries)) {
            return output("changed", {
                attendeeEmails: attendeeEmails,
                missingKeys: missing,
                isSeries: isSeries,
                message: "The event changed since the last review."
            });
        }

        // Append only the reviewed-missing addresses; keep the original
        // required address string for each key.
        var addresses = [];
        payload.reviewedMissingKeys.forEach(function (key) {
            var address = null;
            payload.requiredEmails.forEach(function (email) {
                if (address === null && normalizeEmail(email) === key) address = email;
            });
            addresses.push(address === null ? key : address);
        });

        var appendError = null;
        for (var i = 0; i < addresses.length; i++) {
            try {
                event.attendees.push(Calendar.Attendee({ email: addresses[i] }));
            } catch (e) {
                appendError = String(e.message || e);
                break;
            }
        }

        var warning = null;
        if (appendError === null) {
            try {
                Calendar.reloadCalendars();
            } catch (e) {
                warning = "Calendar may not have refreshed its views: " + String(e.message || e);
            }
        }

        var afterEmails = null;
        try {
            afterEmails = readAttendeeEmails(event);
        } catch (e) {
            afterEmails = null;
        }

        if (afterEmails === null) {
            if (appendError !== null) {
                return output("error", {
                    message: UNCONFIRMED_MESSAGE,
                    warning: appendError
                });
            }
            return output("error", { message: UNCONFIRMED_MESSAGE, warning: warning });
        }

        var added = [];
        var remaining = [];
        payload.reviewedMissingKeys.forEach(function (key) {
            if (missingEmailKeys([key], afterEmails).length === 0) {
                added.push(key);
            } else {
                remaining.push(key);
            }
        });

        if (appendError !== null) {
            return output("error", {
                attendeeEmails: afterEmails,
                addedEmails: added,
                remainingEmails: remaining,
                message: appendError
            });
        }

        var finishWarning = warning;
        if (remaining.length > 0 && finishWarning === null) {
            finishWarning = "Some addresses were not confirmed as added.";
        }
        return output("finished", {
            attendeeEmails: afterEmails,
            addedEmails: added,
            remainingEmails: remaining,
            warning: finishWarning
        });
    } catch (e) {
        return output("error", { message: String(e.message || e) });
    }
}

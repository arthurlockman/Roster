// CalendarRoster.js — JavaScript for Automation used by Roster via
// `osascript -l JavaScript CalendarRoster.js <payload-JSON>`.
//
// Reads/mutates attendees only through Calendar.app scripting. Add-only:
// attendees are appended, never removed or modified, and no RSVP is made.
// The fast preview path lives in the app (EventKit); this script still backs
// the preview when EventKit cannot read the attendee list, and always backs
// the write, so its reads are batched where Calendar allows it: candidate
// uids arrive in one Apple event (then one read per unique candidate; see
// matchesInSpecifier) and attendee emails in one Apple event.
// Identity rule: the calendar is the one whose scripting id equals
// EventKit's calendarIdentifier (measured identical on iCloud, subscribed
// and Birthdays calendars); it must be writable and carry the payload title.
// Only when Calendar cannot resolve that id does the lookup fall back to
// every writable calendar with exactly the payload calendar title. The
// event is tried first by id — Calendar's byId accepts EventKit's
// calendarItemExternalIdentifier (the iCalendar UID) as well as its own
// uid, and rejects unknown ids — and otherwise matched
// conservatively, with exactly one matching event across those calendars,
// by
//   exact title + exact start/end instants (Y/M-D for all-day)
//   + all-day flag,
// and for a recurring-series target the unique recurring master with the same
// title and wall-clock time whose anchor precedes the occurrence and whose
// recurrence (if UNTIL-bounded) has not ended before it. Anything
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

// The UNTIL bound of an RRULE-style recurrence string, or null when the
// rule has none (open-ended or COUNT-bounded). RFC 5545 forms:
//   UNTIL=20261001T065959Z  (UTC instant)
//   UNTIL=20261001T235959   (local wall-clock)
//   UNTIL=20261001          (date only; inclusive, so end of that local day)
function recurrenceUntil(rule) {
    if (typeof rule !== "string") return null;
    var m = /(?:^|;)\s*UNTIL=(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?/i.exec(rule);
    if (!m) return null;
    var y = +m[1], mo = +m[2] - 1, d = +m[3];
    if (m[4] === undefined) return new Date(y, mo, d, 23, 59, 59, 999);
    if (m[7]) return new Date(Date.UTC(y, mo, d, +m[4], +m[5], +m[6]));
    return new Date(y, mo, d, +m[4], +m[5], +m[6]);
}

// A candidate meta is plain data read from one scripting event:
// { summary, allDay, start: Date, end: Date, hasRecurrence, recurrence }.
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
            // A master whose recurrence ended before the occurrence cannot
            // own it. This disambiguates "this and future events" splits,
            // which leave an UNTIL-bounded old master with the same title
            // and time next to the new one.
            var until = recurrenceUntil(candidate.recurrence);
            if (until !== null && until.getTime() < payloadStart.getTime()) return;
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
    if (typeof payload.occurrenceOnly !== "undefined" && typeof payload.occurrenceOnly !== "boolean") {
        throw new Error("Invalid payload: occurrenceOnly must be a boolean");
    }
    if (payload.occurrenceOnly === true && payload.isSeries) {
        throw new Error("Invalid payload: occurrenceOnly targets one event, so isSeries must be false");
    }
    ["knownUID", "calendarIdentifier", "externalIdentifier"].forEach(function (key) {
        if (typeof payload[key] !== "undefined" && typeof payload[key] !== "string") {
            throw new Error("Invalid payload: " + key + " must be a string");
        }
    });
}

// ---- Calendar access ----------------------------------------------------

// Every writable calendar with exactly the payload calendar title. Several
// accounts commonly share a name ("Calendar" on iCloud and Exchange), so
// this returns all of them and findEvent requires exactly one matching
// event across the set. Names arrive in one Apple event; only same-named
// candidates pay a per-calendar writable check.
function findCalendars(Calendar, payload) {
    // Exact path: EventKit's calendarIdentifier is the scripting id. If it
    // resolves, it is the only candidate — a read-only or renamed match
    // fails closed rather than widening to other same-named calendars.
    if (typeof payload.calendarIdentifier === "string" && payload.calendarIdentifier.length > 0) {
        var exact = Calendar.calendars.byId(payload.calendarIdentifier);
        var exactName = null;
        try { exactName = exact.name(); } catch (e0) { exactName = null; }
        if (exactName !== null) {
            var exactWritable = null;
            try { exactWritable = exact.writable(); } catch (e1) { exactWritable = null; }
            if (exactName !== payload.calendarTitle || exactWritable !== true) {
                throw new Error(IDENTITY_MISMATCH_MESSAGE);
            }
            return [exact];
        }
        // Unresolvable id (account type where the ids differ): fall back.
    }
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
    if (matches.length === 0) throw new Error(IDENTITY_MISMATCH_MESSAGE);
    return matches;
}

// Plain-data meta from one event's properties record.
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
        hasRecurrence: typeof recurrence === "string" && recurrence.length > 0,
        recurrence: typeof recurrence === "string" ? recurrence : null,
        uid: typeof properties.uid === "string" ? properties.uid : null
    };
}

// Plain-data meta for one scripting event; read once per candidate.
function candidateMeta(event) {
    var properties = null;
    try { properties = event.properties(); } catch (e) { properties = null; }
    if (properties === null) return null;
    return metaFromProperties(properties);
}

// Matching events for one `whose` specifier.
//
// Measured against Calendar.app on macOS 26: every evaluation of a `whose`
// specifier costs a full calendar scan (~10-30 s on a calendar with years of
// history), each per-event properties read costs ~0.5 s, and a bulk
// `properties()` on a specifier is unsupported (-1728). A `whose` also
// returns a recurring master once per stored occurrence/exception, so a
// series can appear dozens of times; counting those copies as separate
// candidates made every such series look ambiguous.
//
// So: one evaluation fetching just the uids, dedupe, then one byId read per
// unique event. If the uid list cannot be read, fall back to references
// read one at a time, deduplicated by the uid in each properties record.
// Throws when Calendar cannot evaluate the specifier at all.
function matchesInSpecifier(calendar, specifier, payload) {
    var uids = null;
    try { uids = specifier.uid(); } catch (e) { uids = null; }
    if (uids) {
        var unique = [];
        var seen = {};
        var complete = true;
        for (var i = 0; i < uids.length; i++) {
            var uid = uids[i];
            if (typeof uid !== "string" || uid.length === 0) { complete = false; break; }
            if (seen[uid]) continue;
            seen[uid] = true;
            unique.push(uid);
        }
        if (complete) {
            var metas = [];
            var events = [];
            for (var j = 0; j < unique.length; j++) {
                var event = calendar.events.byId(unique[j]);
                var meta = candidateMeta(event);
                if (meta !== null) {
                    metas.push(meta);
                    events.push(event);
                }
            }
            return matchCandidates(metas, payload).map(function (index) { return events[index]; });
        }
    }
    var candidates = specifier();
    var perMetas = [];
    var perEvents = [];
    var seenUIDs = {};
    for (var k = 0; k < candidates.length; k++) {
        var candidate = candidateMeta(candidates[k]);
        if (candidate === null) continue;
        if (typeof candidate.uid === "string" && candidate.uid.length > 0) {
            if (seenUIDs[candidate.uid]) continue;
            seenUIDs[candidate.uid] = true;
        }
        perMetas.push(candidate);
        perEvents.push(candidates[k]);
    }
    return matchCandidates(perMetas, payload).map(function (index) { return perEvents[index]; });
}

// All events in one calendar matching the payload identity.
//
// Non-series payloads match by exact instants, so the scan is first
// date-windowed server-side: Calendar returns a handful of candidates even
// in a calendar with years of history. Calendar's whose evaluator rejects
// _greaterThanOrEquals/_lessThanOrEquals on dates (-1726) but accepts strict
// _greaterThan/_lessThan, so the bounds are widened instead. Series targets
// are recurring masters whose anchor can be arbitrarily old, so they use
// the title-only scan (also the windowed scan's fallback). If Calendar
// cannot evaluate either, this fails closed rather than reading every event
// in the calendar one Apple event at a time.
function scanCalendar(calendar, payload) {
    var titleOnly = { summary: { _equals: payload.title } };
    var specifiers = [];
    if (!payload.isSeries) {
        var payloadStart = new Date(payload.startDate);
        var lo = new Date(payloadStart.getTime() - 3 * 86400000);
        var hi = new Date(payloadStart.getTime() + 3 * 86400000);
        specifiers.push(calendar.events.whose({ _and: [
            titleOnly,
            { startDate: { _greaterThan: lo } },
            { startDate: { _lessThan: hi } }
        ] }));
    }
    specifiers.push(calendar.events.whose(titleOnly));
    for (var i = 0; i < specifiers.length; i++) {
        try {
            return matchesInSpecifier(calendar, specifiers[i], payload);
        } catch (e) {
            // Try the next, broader specifier.
        }
    }
    throw new Error(IDENTITY_MISMATCH_MESSAGE);
}

// EventKit gives a detached (individually edited) occurrence the external
// identifier "<series uid>/RID=<n>", and Calendar's byId resolves that to
// the single occurrence. Roster only ever writes to the whole series, so the
// suffix is dropped and the id resolves to the series master instead.
function isDetachedIdentifier(identifier) {
    return typeof identifier === "string" && identifier.indexOf("/RID=") >= 0;
}

function seriesExternalIdentifier(identifier) {
    if (typeof identifier !== "string") return identifier;
    var index = identifier.indexOf("/RID=");
    return index >= 0 ? identifier.slice(0, index) : identifier;
}

// The single changed occurrence the user chose to edit on its own. Only its
// own "<series uid>/RID=<n>" identifier addresses it; knownUID and a scan
// would both address the series master, so neither is used, and anything
// short of an exact title/start/end match on that occurrence fails closed.
function findChangedOccurrence(calendars, payload) {
    if (!isDetachedIdentifier(payload.externalIdentifier)) throw new Error(IDENTITY_MISMATCH_MESSAGE);
    var occurrence = null;
    try { occurrence = calendars[0].events.byId(payload.externalIdentifier); } catch (e) { occurrence = null; }
    var meta = null;
    if (occurrence) {
        try { meta = candidateMeta(occurrence); } catch (e2) { meta = null; }
    }
    if (meta === null || matchCandidates([meta], payload).length !== 1) throw new Error(IDENTITY_MISMATCH_MESSAGE);
    return occurrence;
}

// Exactly one event across the candidate calendars matching the payload
// identity.
//
// Fast path: `knownUID` was captured by a read-only locate run earlier in
// this flow, which already required exactly one match across the
// candidate calendars; `externalIdentifier` comes from EventKit. byId resolves in milliseconds while a whose scan
// costs tens of seconds on large calendars. Calendar resolves event ids
// globally — `calendars[a].events.byId(uid)` returns the event even when it
// lives in calendar b, and Calendar's own whose results are addressed the
// same way — so the uid is resolved once, not per calendar (per-calendar
// lookups made one event look like several and forced the slow scan). The
// identity check still runs on the resolved event, so a stale or wrong uid
// can only cost the fallback scan — never a wrong write.
function findEvent(calendars, payload) {
    if (payload.occurrenceOnly === true) return findChangedOccurrence(calendars, payload);
    // knownUID (from a locate run) first, then EventKit's external
    // identifier (the iCalendar UID), which Calendar's byId also accepts.
    var tried = {};
    var uids = [payload.knownUID, seriesExternalIdentifier(payload.externalIdentifier)];
    for (var u = 0; u < uids.length; u++) {
        var uid = uids[u];
        if (typeof uid !== "string" || uid.length === 0 || tried[uid]) continue;
        tried[uid] = true;
        var cached = null;
        try { cached = calendars[0].events.byId(uid); } catch (e) { cached = null; }
        if (!cached) continue;
        var cachedMeta = null;
        try { cachedMeta = candidateMeta(cached); } catch (e2) { cachedMeta = null; }
        if (cachedMeta !== null && matchCandidates([cachedMeta], payload).length === 1) {
            return cached;
        }
        if (cachedMeta !== null && uid !== payload.knownUID && isDetachedIdentifier(payload.externalIdentifier)) {
            // The edited occurrence's own series master does not match it
            // (typically: the occurrence was moved to another time). A search
            // could only find some other series with the same title and
            // time, so fail closed now instead of after a long scan.
            throw new Error(IDENTITY_MISMATCH_MESSAGE);
        }
    }
    // No usable uid: fall through to the full conservative match.

    var matches = [];
    for (var i = 0; i < calendars.length; i++) {
        matches = matches.concat(scanCalendar(calendars[i], payload));
        if (matches.length > 1) break;
    }
    if (matches.length !== 1) throw new Error(IDENTITY_MISMATCH_MESSAGE);
    return matches[0];
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
        // Apple event error number (e.g. -1743 not authorized, -1712
        // timeout) so the app can explain the failure without parsing text.
        errorNumber: typeof fields.errorNumber === "number" ? fields.errorNumber : null,
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

        var event = findEvent(findCalendars(Calendar, payload), payload);

        // A changed occurrence edited on its own is one event, not a series,
        // even though Calendar reports its series' recurrence on it.
        var isSeries = payload.occurrenceOnly === true ? false : seriesFlag(event);

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

        // No reloadCalendars here: the additions are committed by the push
        // itself and synced by the account. A/B testing on real drops showed
        // the same result and invite delivery without it, and it refreshed
        // every account in Calendar.

        // Calendar can take a moment to finish saving, especially for an
        // occurrence edited on its own: reading back right away has failed or
        // returned the old list even though the write landed. Re-read a few
        // times before deciding the write is unconfirmed (~1 s at most).
        var afterEmails = null;
        var verifyError = null;
        for (var attempt = 0; attempt < 4; attempt++) {
            if (attempt > 0) delay(0.25);
            try {
                afterEmails = readAttendeeEmails(event);
                verifyError = null;
            } catch (e) {
                afterEmails = null;
                verifyError = String(e.message || e);
            }
            if (afterEmails !== null && missingEmailKeys(payload.reviewedMissingKeys, afterEmails).length === 0) break;
            if (appendError !== null) break; // Nothing more is coming; report now.
        }

        if (afterEmails === null) {
            return output("error", {
                message: UNCONFIRMED_MESSAGE,
                warning: appendError !== null ? appendError : "Reading invitees back failed: " + verifyError
            });
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

        var finishWarning = remaining.length > 0 ? "Some addresses were not confirmed as added." : null;
        return output("finished", {
            attendeeEmails: afterEmails,
            addedEmails: added,
            remainingEmails: remaining,
            warning: finishWarning
        });
    } catch (e) {
        return output("error", { message: String(e.message || e), errorNumber: e.errorNumber });
    }
}

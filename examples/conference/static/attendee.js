// An attendee receives and sends nothing. Three recvonly transceivers are
// opened in the order the speaker's tracks are in — microphone, camera,
// desktop — and each is recognised again by its media identifier when the
// track for it arrives, which is steadier than going by the order the tracks
// happen to be delivered in.

const SESSION_HEADER = "X-Conference-Session";
const parameters = new URLSearchParams(location.search);
const name = decodeURIComponent(location.pathname.split("/")[1]);

const joinButton = document.getElementById("join");
const status = document.getElementById("status");
const watchers = document.getElementById("watchers");
const elements = {
  audio: document.getElementById("audio"),
  camera: document.getElementById("camera"),
  screen: document.getElementById("screen"),
};

document.getElementById("conference").textContent = name;
document.getElementById("address").textContent =
  location.origin + "/" + name + "/speaker";

let connection = null;
let session = null;

function show(what, on) {
  if (what === "audio") return;
  elements[what].parentElement.classList.toggle("idle", !on);
}

// Telling the server now, rather than leaving it to notice that the checks
// have stopped coming.
function stopSession(id) {
  fetch("/" + encodeURIComponent(name) + "/stop", {
    method: "POST",
    headers: { [SESSION_HEADER]: id },
  }).catch(() => {});
}

async function join() {
  // Everything below works on this connection rather than on the variable:
  // leaving happens on an event, which can land in any of the awaits here, and
  // what it leaves behind — a null, or the connection of a later join — must
  // not be mistaken for the one this offer was made on.
  const pc = new RTCPeerConnection({ iceServers: [] });
  connection = pc;
  const wanted = new Map();
  for (const [what, kind] of [
    ["audio", "audio"],
    ["camera", "video"],
    ["screen", "video"],
  ]) {
    wanted.set(pc.addTransceiver(kind, { direction: "recvonly" }), what);
  }

  pc.ontrack = (event) => {
    const what = wanted.get(event.transceiver);
    if (!what) return;
    // A stream of our own per element: the server groups the microphone with
    // the camera so that a browser plays them in step, but they are watched
    // in two elements, and the desktop in a third.
    elements[what].srcObject = new MediaStream([event.track]);
    // A track is muted until its packets start arriving, and again when they
    // stop — which is what the speaker not sharing the desktop looks like
    // from here, since the section for it is negotiated either way.
    show(what, !event.track.muted);
    event.track.onunmute = () => show(what, true);
    event.track.onmute = () => show(what, false);
  };
  pc.onconnectionstatechange = () => {
    // A connection that has been left still has its last states to report.
    if (connection !== pc) return;
    status.textContent = pc.connectionState;
    if (pc.connectionState === "failed") leave();
  };

  await pc.setLocalDescription(await pc.createOffer());
  const response = await fetch("/" + encodeURIComponent(name) + "/offer", {
    method: "POST",
    headers: { "Content-Type": "application/sdp" },
    body: pc.localDescription.sdp,
  });
  if (!response.ok) throw new Error(await response.text());
  const ufrag = response.headers.get(SESSION_HEADER);
  // Left while the exchange was in flight, so the session the server has just
  // opened is one nobody is on the other end of: leave() could not have said
  // so, not knowing yet what it was called.
  if (connection !== pc) return stopSession(ufrag);
  session = ufrag;
  await pc.setRemoteDescription({
    type: "answer",
    sdp: await response.text(),
  });
}

function leave() {
  if (session) {
    stopSession(session);
    session = null;
  }
  if (connection) {
    connection.close();
    connection = null;
  }
  for (const what of Object.keys(elements)) {
    elements[what].srcObject = null;
    show(what, false);
  }
  joinButton.textContent = "Join";
  status.textContent = "idle";
}

joinButton.onclick = async () => {
  joinButton.disabled = true;
  try {
    if (connection) leave();
    else {
      await join();
      // Unless it was left again while the offer was in flight.
      if (connection) joinButton.textContent = "Leave";
    }
  } catch (error) {
    leave();
    // After leaving, which would otherwise write "idle" over it.
    status.textContent = error;
  }
  joinButton.disabled = false;
};

window.addEventListener("pagehide", leave);

async function poll() {
  try {
    const state = await (
      await fetch("/" + encodeURIComponent(name) + "/status")
    ).json();
    watchers.textContent = state.speaker
      ? "the speaker is connected"
      : "waiting for the speaker";
  } catch (error) {
    /* the page is being left */
  }
}

poll();
setInterval(poll, 3000);

// Lets a headless browser exercise the whole path without a click:
// /name?autostart
if (parameters.has("autostart")) joinButton.click();

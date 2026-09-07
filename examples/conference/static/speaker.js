// The speaker's half of a conference: microphone, camera and desktop, sent to
// the server as three sendonly tracks. The server is an ICE-lite agent, so it
// answers with host candidates of its own and ignores the ones we gather:
// there is nothing to trickle and nothing to wait for.
//
// All three transceivers are opened at once, the desktop's without a track.
// Sharing then replaces a track on a sender that already exists, which needs
// no renegotiation — and the section keeps its place in the offer, which is
// how the server knows the desktop from the camera.

const SESSION_HEADER = "X-Conference-Session";
const parameters = new URLSearchParams(location.search);
const name = decodeURIComponent(location.pathname.split("/")[1]);

const connectButton = document.getElementById("connect");
const shareButton = document.getElementById("share");
const status = document.getElementById("status");
const watchers = document.getElementById("watchers");
const cameraVideo = document.getElementById("camera");
const screenVideo = document.getElementById("screen");

document.getElementById("conference").textContent = name;
document.getElementById("address").textContent = location.origin + "/" + name;

let connection = null;
let session = null;
let cameraStream = null;
let screenStream = null;
let screenSender = null;
let negotiating = false;

function show(element, on) {
  element.parentElement.classList.toggle("idle", !on);
}

// One exchange of SDP. The same request serves the first offer and any that
// follow it: the session header says which session is being renegotiated, and
// its absence asks for a new one.
async function negotiate() {
  if (negotiating) return;
  negotiating = true;
  try {
    await connection.setLocalDescription(await connection.createOffer());
    const headers = { "Content-Type": "application/sdp" };
    if (session) headers[SESSION_HEADER] = session;
    const response = await fetch("/" + encodeURIComponent(name) + "/speaker/offer", {
      method: "POST",
      headers,
      body: connection.localDescription.sdp,
    });
    if (!response.ok) throw new Error(await response.text());
    session = response.headers.get(SESSION_HEADER);
    await connection.setRemoteDescription({
      type: "answer",
      sdp: await response.text(),
    });
  } finally {
    negotiating = false;
  }
}

async function connect() {
  cameraStream = await navigator.mediaDevices.getUserMedia({
    audio: true,
    video: true,
  });
  cameraVideo.srcObject = cameraStream;
  show(cameraVideo, true);

  connection = new RTCPeerConnection({ iceServers: [] });
  connection.addTransceiver(cameraStream.getAudioTracks()[0], {
    direction: "sendonly",
  });
  const camera = connection.addTransceiver(cameraStream.getVideoTracks()[0], {
    direction: "sendonly",
  });
  // The desktop's section, held open with nothing on it yet.
  const screen = connection.addTransceiver("video", { direction: "sendonly" });
  screenSender = screen.sender;
  prefer(camera);
  prefer(screen);

  connection.onconnectionstatechange = () => {
    if (!connection) return;
    status.textContent = connection.connectionState;
    if (connection.connectionState === "failed") stop();
  };
  // Not expected — replacing a track needs no renegotiation — but a browser
  // is entitled to ask, and answering is one request.
  connection.onnegotiationneeded = () => {
    if (session) negotiate().catch((error) => (status.textContent = error));
  };

  await negotiate();
  shareButton.disabled = false;
}

async function share() {
  screenStream = await navigator.mediaDevices.getDisplayMedia({
    video: true,
    // A headless browser has no desktop to pick from, but it can be told to
    // hand over the tab it is already showing; see ?autoshare below.
    preferCurrentTab: parameters.has("autoshare"),
  });
  const track = screenStream.getVideoTracks()[0];
  // The user can also stop sharing from the browser's own control.
  track.onended = () => unshare();
  await screenSender.replaceTrack(track);
  screenVideo.srcObject = screenStream;
  show(screenVideo, true);
  shareButton.textContent = "Stop sharing";
}

async function unshare() {
  if (screenStream) {
    screenStream.getTracks().forEach((track) => track.stop());
    screenStream = null;
  }
  if (screenSender) await screenSender.replaceTrack(null);
  screenVideo.srcObject = null;
  show(screenVideo, false);
  shareButton.textContent = "Share desktop";
}

function stop() {
  // Tell the server now, rather than leaving it to notice that the checks
  // have stopped coming.
  if (session) {
    fetch("/" + encodeURIComponent(name) + "/stop", {
      method: "POST",
      headers: { [SESSION_HEADER]: session },
    });
    session = null;
  }
  unshare();
  if (connection) {
    connection.close();
    connection = null;
  }
  if (cameraStream) {
    cameraStream.getTracks().forEach((track) => track.stop());
    cameraStream = null;
  }
  cameraVideo.srcObject = null;
  show(cameraVideo, false);
  screenSender = null;
  shareButton.disabled = true;
  connectButton.textContent = "Connect";
  status.textContent = "idle";
}

// The browser offers every video codec it has and the server takes the first
// it knows, which is VP8. Narrowing the offer is the only way to reach the
// others: /name/speaker?codec=vp9 (or h264).
function prefer(transceiver) {
  const wanted = parameters.get("codec");
  if (!wanted || !transceiver.setCodecPreferences) return;
  const { codecs } = RTCRtpSender.getCapabilities("video");
  const matching = codecs.filter(
    (codec) => codec.mimeType.toLowerCase() === "video/" + wanted.toLowerCase(),
  );
  if (matching.length === 0) throw new Error("no such video codec: " + wanted);
  const auxiliary = codecs.filter((codec) =>
    /\/(rtx|red|ulpfec|flexfec)/i.test(codec.mimeType),
  );
  transceiver.setCodecPreferences(matching.concat(auxiliary));
}

connectButton.onclick = async () => {
  connectButton.disabled = true;
  try {
    if (connection) stop();
    else {
      await connect();
      connectButton.textContent = "Disconnect";
    }
  } catch (error) {
    stop();
    // After stop, which would otherwise write "idle" over it.
    status.textContent = error;
  }
  connectButton.disabled = false;
};

shareButton.onclick = async () => {
  shareButton.disabled = true;
  try {
    if (screenStream) await unshare();
    else await share();
  } catch (error) {
    // Declining the browser's own picker ends up here, and is not an error.
    status.textContent = error;
  }
  shareButton.disabled = false;
};

window.addEventListener("pagehide", stop);

async function poll() {
  try {
    const state = await (
      await fetch("/" + encodeURIComponent(name) + "/status")
    ).json();
    watchers.textContent =
      state.attendees === 0
        ? "nobody is watching yet"
        : state.attendees === 1
          ? "one person is watching"
          : state.attendees + " people are watching";
  } catch (error) {
    /* the page is being left */
  }
}

poll();
setInterval(poll, 3000);

// Lets a headless browser exercise the whole path without a click:
// /name/speaker?autostart, and ?autostart&autoshare to share the desktop too,
// which needs --auto-accept-this-tab-capture on the browser.
if (parameters.has("autostart")) {
  connectButton.onclick().then(() => {
    if (parameters.has("autoshare")) shareButton.onclick();
  });
}

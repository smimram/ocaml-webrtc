(** An offer of the shape browsers write, parsed, and the answers made to it
    read back with the same parser. *)

open Testlib

(* Chrome's own offer for a microphone and two cameras, cut down to the lines
   this parser looks at: three sections on one bundled transport, the video
   ones sharing every payload type, told apart only by their sources. *)
let offer =
  String.concat "\r\n"
    [
      "v=0";
      "o=- 4611731400430051336 2 IN IP4 127.0.0.1";
      "s=-";
      "t=0 0";
      "a=group:BUNDLE 0 1 2";
      "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8";
      "c=IN IP4 0.0.0.0";
      "a=ice-ufrag:4ZcD";
      "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlga";
      "a=fingerprint:sha-256 \
       75:74:5A:A6:A5:E5:45:6A:52:6C:6D:32:14:AE:8D:CD:E9:C9:52:9E:B6:8C:F2:1B:52:1A:37:22:F1:1A:F4:C0";
      "a=setup:actpass";
      "a=mid:0";
      "a=sendonly";
      "a=rtcp-mux";
      "a=rtpmap:111 opus/48000/2";
      "a=fmtp:111 minptime=10;useinbandfec=1";
      "a=rtpmap:63 red/48000/2";
      "a=ssrc:1111111 cname:speaker";
      "a=ssrc:1111111 msid:microphone track-a";
      "m=video 9 UDP/TLS/RTP/SAVPF 96 97 39 40";
      "c=IN IP4 0.0.0.0";
      "a=mid:1";
      "a=sendonly";
      "a=rtcp-mux";
      "a=rtcp-fb:96 nack";
      "a=rtcp-fb:96 nack pli";
      "a=rtpmap:96 VP8/90000";
      "a=rtpmap:97 rtx/90000";
      "a=fmtp:97 apt=96";
      "a=rtpmap:39 H264/90000";
      "a=fmtp:39 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f";
      "a=rtpmap:40 H264/90000";
      "a=fmtp:40 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f";
      "a=ssrc:2222222 cname:speaker";
      "m=video 9 UDP/TLS/RTP/SAVPF 96 97";
      "c=IN IP4 0.0.0.0";
      "a=mid:2";
      "a=sendonly";
      "a=rtcp-mux";
      "a=rtpmap:96 VP8/90000";
      "a=ssrc:3333333 cname:speaker";
      "";
    ]

let run () =
  suite "sdp";

  let parsed = Sdp.parse_offer offer in
  check "the transport is read from the first section that has it"
    (parsed.ice_ufrag = "4ZcD" && parsed.ice_pwd = "2/1muCWoOi3uLifh0NuRHlga");
  check "the fingerprint keeps its algorithm and its digest"
    (fst parsed.fingerprint = "sha-256"
    && String.length (snd parsed.fingerprint) = 95);
  check "every section is kept, in order"
    (List.map (fun (m : Sdp.media) -> m.mid) parsed.media = [ "0"; "1"; "2" ]);
  check "the section a browser sends on is sendonly"
    (List.for_all (fun (m : Sdp.media) -> m.direction = Sdp.Sendonly) parsed.media);

  let audio = List.nth parsed.media 0 in
  let camera = List.nth parsed.media 1 in
  let screen = List.nth parsed.media 2 in
  check "Opus is chosen for audio, redundancy is not"
    (match audio.codec with
    | Some c -> c.payload_type = 111 && c.channels = 2
    | None -> false);
  check "VP8 is chosen for video, and its spelling is kept"
    (match camera.codec with Some c -> c.name = "VP8" | None -> false);
  check "picture loss indication was offered on it"
    (match camera.codec with Some c -> c.pli | None -> false);

  (* The two video sections are identical but for their sources, which is
     what a forwarder has to route by. *)
  check "each section declares its source once, however often it is named"
    (audio.ssrcs = [ 1111111l ]
    && camera.ssrcs = [ 2222222l ]
    && screen.ssrcs = [ 3333333l ]);

  (* Following someone else's choice of codec rather than making our own. *)
  let h264 =
    List.find (fun (c : Sdp.codec) -> c.payload_type = 39) camera.codecs
  in
  check "every format of a section is kept, not only the chosen one"
    (List.length camera.codecs = 4);
  check "a codec no section of the offer has is not found in it"
    (match Sdp.matching h264 screen.codecs with None -> true | Some _ -> false);
  check "and found again in a section that has it"
    (match Sdp.matching h264 camera.codecs with
    | Some c -> c.payload_type = 39
    | None -> false);
  check "H.264 of another packetization mode is not the same stream"
    (match
       Sdp.matching h264
         (List.filter (fun (c : Sdp.codec) -> c.payload_type = 40) camera.codecs)
     with
    | None -> true
    | Some _ -> false);
  check "an encoding spelled differently is still the same one"
    (match
       Sdp.matching
         { h264 with name = "vp8"; fmtp = None }
         (Option.to_list camera.codec)
     with
    | Some c -> c.name = "VP8"
    | None -> false);

  suite "sdp answer";

  let answer ?sending () =
    Sdp.answer ~offer:parsed ?sending ~addresses:[ "192.0.2.1"; "127.0.0.1" ]
      ~port:7000 ~ice_ufrag:"abcd" ~ice_pwd:"0123456789abcdefghijkl"
      ~fingerprint:("sha-256", "AA:BB") ()
  in

  (* An answer is an offer as far as this parser is concerned, so it can be
     read back to see what it says. *)
  let received = Sdp.parse_offer (answer ()) in
  check "a receiver answers recvonly throughout"
    (List.for_all
       (fun (m : Sdp.media) -> m.direction = Sdp.Recvonly)
       received.media);
  check "on the payload types the offer used"
    (List.map (fun (m : Sdp.media) -> Option.map (fun (c : Sdp.codec) -> c.payload_type) m.codec)
       received.media
    = [ Some 111; Some 96; Some 96 ]);
  check "no source is signalled by a receiver"
    (List.for_all (fun (m : Sdp.media) -> m.ssrcs = []) received.media);

  let sending (m : Sdp.media) =
    if m.mid = "0" then
      Some
        { Sdp.ssrc = Int32.of_string "0u4000000000"; cname = "sfu"; stream = "s"; track = "audio" }
    else None
  in
  let mixed = answer ~sending () in
  let read = Sdp.parse_offer mixed in
  check "a section we send on is sendonly"
    (List.map (fun (m : Sdp.media) -> m.direction) read.media
    = [ Sdp.Sendonly; Sdp.Recvonly; Sdp.Recvonly ]);
  check "and carries the source its packets will"
    (List.map (fun (m : Sdp.media) -> m.ssrcs) read.media
    = [ [ Int32.of_string "0u4000000000" ]; []; [] ]);
  check "a source above two billion is written unsigned"
    (let needle = "a=ssrc:4000000000 cname:sfu" in
     let rec find i =
       i + String.length needle <= String.length mixed
       && (String.sub mixed i (String.length needle) = needle || find (i + 1))
     in
     find 0);
  check "the track is named as well, so that a peer can bind it"
    (let needle = "a=msid:s audio" in
     let rec find i =
       i + String.length needle <= String.length mixed
       && (String.sub mixed i (String.length needle) = needle || find (i + 1))
     in
     find 0);

  (* Answering with a codec of someone else's choosing: what a forwarder does
     when the peer it is forwarding from settled on H.264. *)
  let media =
    List.map
      (fun (m : Sdp.media) ->
        if m.kind = "video" then { m with codec = Sdp.matching h264 m.codecs }
        else m)
      parsed.media
  in
  let followed =
    Sdp.parse_offer
      (Sdp.answer ~offer:parsed ~media ~addresses:[ "192.0.2.1" ] ~port:7000
         ~ice_ufrag:"abcd" ~ice_pwd:"0123456789abcdefghijkl"
         ~fingerprint:("sha-256", "AA:BB") ())
  in
  check "the overridden codec is what the answer names"
    (match (List.nth followed.media 1).codec with
    | Some c -> c.payload_type = 39 && c.name = "H264"
    | None -> false);
  check "and a section that cannot do it is rejected outright"
    (let rejected = List.nth followed.media 2 in
     rejected.codec = None && rejected.direction = Sdp.Inactive)

let () =
  run ();
  exit_status ()

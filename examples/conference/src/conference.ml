(** A conferencing server: one speaker sends microphone, camera and desktop,
    and everyone else watches.

    It is a selective forwarding unit. The speaker sends one copy of each
    track; every packet of it is authenticated and decrypted under the
    speaker's SRTP context, has its source and its numbering rewritten, and is
    encrypted again under each attendee's. No codec is ever run — what an
    attendee sees is the very bitstream the speaker's encoder produced.

    Signalling is a plain HTTP exchange of SDP, and media arrives on a single
    UDP socket shared by every session of every conference, on which STUN,
    DTLS and SRTP are multiplexed (RFC 7983). *)

let static_root = ref "examples/conference/static"
let http_port = ref 8080
let http_interface = ref "localhost"
let media_port = ref 7000

(* The addresses we advertise as host candidates, most preferred first; see
   the "advertised address" section of CLAUDE.md for why several. *)
let advertised_ips = ref []
let bind_ip = ref None
let debug = ref false

(* Which address the kernel would use to reach the outside world. Connecting a
   datagram socket sends nothing: it only consults the routing table. The
   address is from the range reserved for documentation, so nothing can come of
   it even if a packet were sent. *)
let primary_address () =
  let socket = Unix.socket PF_INET SOCK_DGRAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      match
        Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_of_string "203.0.113.1", 9));
        Unix.getsockname socket
      with
      | Unix.ADDR_INET (ip, _) -> [ Unix.string_of_inet_addr ip ]
      | _ | (exception Unix.Unix_error _) -> [])

let default_addresses () = primary_address () @ [ "127.0.0.1" ]

let log = Dream.sub_log "conference"

(* Tracks ------------------------------------------------------------------ *)

(* What a speaker sends. The three are fixed rather than discovered: the page
   opens one transceiver for each up front, so that starting to share the
   desktop replaces a track on a transceiver that already exists and needs no
   renegotiation. Their order in the offer is therefore always this one. *)
type kind = Audio | Camera | Screen

let string_of_kind = function
  | Audio -> "audio"
  | Camera -> "camera"
  | Screen -> "screen"

(* One track of the speaker's, as it arrives. *)
type incoming = {
  kind : kind;
  codec : Sdp.codec;
  (* [None] for audio, which has no notion of a picture to reassemble or to
     ask for. *)
  format : Rtp.Frame.codec option;
  (* The sources the offer declared for this section. Two video tracks share a
     transport and a payload type under BUNDLE, so this is the only thing that
     tells their packets apart. *)
  declared : int32 list;
  mutable ssrc : int32 option;
  mutable reception : Rtp.Reception.t;
  (* The last sender report, and when it arrived: the pairing of the stream's
     clock with the wall clock, which is what has to survive forwarding for an
     attendee to play the camera in step with the microphone. *)
  mutable clock : (float * Rtp.Rtcp.sender_info) option;
  mutable highest : int option;  (** highest sequence number seen, for loss *)
  mutable arrived : float;  (** when a packet last arrived on it *)
  mutable asked_at : float;  (** when a keyframe was last asked for *)
}

(* One track of one attendee: the same media, renumbered and re-sourced for
   this one peer. *)
type forward = {
  kind : kind;
  out_ssrc : int32;
  payload_type : int;  (** the attendee's own numbering, not the speaker's *)
  clock_rate : int;
  format : Rtp.Frame.codec option;
  (* The speaker source these offsets were computed against. A speaker that
     reconnects sends a new one, and everything has to be rebased. *)
  mutable source : int32 option;
  mutable sequence_offset : int;
  mutable timestamp_offset : int32;
  (* Whether a point has been seen at which this attendee could join. Video
     stays shut until a keyframe: anything else decodes into a picture built
     on frames the attendee never had. *)
  mutable started : bool;
  mutable highest : int;  (** highest sequence number sent *)
  mutable timestamp : int32;
  mutable packets : int32;
  mutable octets : int32;
}

(* Sessions ---------------------------------------------------------------- *)

type session = {
  conference : conference;
  role : role;
  ice : Ice.Agent.t;
  dtls : Dtls.Server.t;
  mutable srtp : Srtp.t option;
  mutable srtp_sender : Srtp.sender option;
  (* Ours, which names us in the reports and the feedback we send. An
     attendee's media travels under the sources of its forwards instead. *)
  sender_ssrc : int32;
  (* The name that stays put when a synchronisation source does not (RFC 3550
     §6.5). *)
  cname : string;
  created : float;
}

and role = Speaker of speaker | Attendee of attendee
and speaker = { mutable tracks : incoming list }
and attendee = { mutable forwards : forward list }

and conference = {
  name : string;
  mutable speaker : session option;
  mutable attendees : session list;
  (* What everyone in this conference speaks. A forwarder cannot transcode, so
     one codec has to do for all of them; the speaker settles it, and an
     attendee that cannot manage it is answered with that section rejected. *)
  mutable audio_codec : Sdp.codec option;
  mutable video_codec : Sdp.codec option;
}

let ufrag session = (Ice.Agent.local session.ice).ufrag

(* Sessions are found by the ICE fragment a STUN check carries, and by source
   address once a peer has been latched, since DTLS and RTP datagrams identify
   themselves in no other way. *)
let sessions : (string, session) Hashtbl.t = Hashtbl.create 16
let sessions_by_peer : (Unix.sockaddr, session) Hashtbl.t = Hashtbl.create 16
let conferences : (string, conference) Hashtbl.t = Hashtbl.create 16

let certificate = lazy (Dtls.Certificate.generate ())
let dtls_config = lazy (Dtls.Server.config (Lazy.force certificate))

let session_header = "X-Conference-Session"

let conference name =
  match Hashtbl.find_opt conferences name with
  | Some conference -> conference
  | None ->
      let conference =
        {
          name;
          speaker = None;
          attendees = [];
          audio_codec = None;
          video_codec = None;
        }
      in
      Hashtbl.replace conferences name conference;
      log.info (fun log -> log "conference %S opened" name);
      conference

let forget session =
  let conference = session.conference in
  (match session.role with
  | Speaker _ -> (
      match conference.speaker with
      | Some current when current == session -> conference.speaker <- None
      | _ -> ())
  | Attendee _ ->
      conference.attendees <-
        List.filter (fun other -> other != session) conference.attendees);
  Hashtbl.remove sessions (ufrag session);
  Option.iter (Hashtbl.remove sessions_by_peer) (Ice.Agent.peer session.ice);
  (* A conference is nothing but the sessions in it. *)
  if
    Option.is_none conference.speaker
    && match conference.attendees with [] -> true | _ -> false
  then begin
    Hashtbl.remove conferences conference.name;
    log.info (fun log -> log "conference %S closed" conference.name)
  end

(* Negotiation ------------------------------------------------------------- *)

(* Which track a section of the offer is: the first audio section, then the
   video sections in the order the page opened them. Anything beyond that —
   a data channel, a third camera — is answered rejected. *)
let kinds media =
  let audio = ref 0 and video = ref 0 in
  List.map
    (fun (m : Sdp.media) ->
      match m.kind with
      | "audio" ->
          incr audio;
          (m, if !audio = 1 then Some Audio else None)
      | "video" ->
          incr video;
          (m, match !video with 1 -> Some Camera | 2 -> Some Screen | _ -> None)
      | _ -> (m, None))
    media

let format_of_codec (codec : Sdp.codec) =
  match String.lowercase_ascii codec.name with
  | "vp8" -> Some Rtp.Frame.Vp8
  | "vp9" -> Some Rtp.Frame.Vp9
  | "h264" -> Some Rtp.Frame.H264
  | _ -> None

(* One codec per kind for the whole conference, since nothing here can
   transcode. The speaker settles it — it is the one peer whose encoder we
   have no other way to influence — and everyone else is matched to what it
   chose. An attendee that offers nothing equivalent loses that section. *)
let choose_codec conference ~speaking kind (media : Sdp.media) =
  let established =
    match kind with
    | Audio -> conference.audio_codec
    | Camera | Screen -> conference.video_codec
  in
  let chosen =
    match established with
    | None -> media.codec
    | Some codec -> (
        match Sdp.matching codec media.codecs with
        | Some codec -> Some codec
        (* The speaker is not refused a codec of its own; the conference
           follows it, and attendees already connected are told. *)
        | None -> if speaking then media.codec else None)
  in
  (* What the conference speaks is the speaker's choice, and an attendee's
     only for as long as there is no speaker to say otherwise. *)
  (match chosen with
  | Some codec when speaking || Option.is_none established ->
      (match established with
      | Some previous when Option.is_none (Sdp.matching previous [ codec ]) ->
          log.warning (fun log ->
              log
                "conference %S: the speaker chose %s where %s was in use; \
                 attendees connected before now must rejoin"
                conference.name codec.name previous.name)
      | _ -> ());
      if kind = Audio then conference.audio_codec <- Some codec
      else conference.video_codec <- Some codec
  | _ -> ());
  chosen

(* Synchronisation sources, sequence numbers and names have to be
   unpredictable (RFC 3550 §8.1), and there may be many of them at once: one
   source per track per attendee. They come from the same generator the rest
   of the stack draws on rather than from [Random], whose default seed is the
   same on every run. *)
let random_int32 () = String.get_int32_be (Mirage_crypto_rng.generate 4) 0
let random_sequence () = String.get_uint16_be (Mirage_crypto_rng.generate 2) 0

let random_cname () =
  (* Not who we are: RFC 7022 asks only that it be unlikely to collide. *)
  String.concat ""
    (List.map
       (fun c -> Printf.sprintf "%02x" (Char.code c))
       (List.of_seq (String.to_seq (Mirage_crypto_rng.generate 8))))

let incoming_of_media ~kind ~(codec : Sdp.codec) (media : Sdp.media) =
  {
    kind;
    codec;
    format = format_of_codec codec;
    declared = media.ssrcs;
    ssrc = None;
    reception = Rtp.Reception.create ~clock_rate:codec.clock_rate;
    clock = None;
    highest = None;
    arrived = 0.;
    asked_at = 0.;
  }

let forward_of_codec ~kind ~(codec : Sdp.codec) =
  {
    kind;
    out_ssrc = random_int32 ();
    payload_type = codec.payload_type;
    clock_rate = codec.clock_rate;
    format = format_of_codec codec;
    source = None;
    sequence_offset = 0;
    timestamp_offset = 0l;
    started = false;
    (* Where our numbering begins. RFC 3550 §5.1 wants both unpredictable, and
       a fresh session of an attendee that reconnected must not look like a
       continuation of the one before. *)
    highest = random_sequence ();
    timestamp = random_int32 ();
    packets = 0l;
    octets = 0l;
  }

(* The answer, and the session it belongs to. Both roles share this: they
   differ in what they do with the sections, not in how the transport is set
   up. *)
let negotiate ~conference ~speaking ~existing offer =
  let sections = kinds offer.Sdp.media in
  let chosen =
    List.map
      (fun (media, kind) ->
        ( media,
          kind,
          match kind with
          | None -> None
          | Some kind -> choose_codec conference ~speaking kind media ))
      sections
  in
  let media =
    List.map
      (fun ((media : Sdp.media), _, codec) -> { media with codec })
      chosen
  in
  let session =
    match existing with
    | Some session -> session
    | None ->
        let ice =
          Ice.Agent.create
            ~remote:{ ufrag = offer.Sdp.ice_ufrag; pwd = offer.Sdp.ice_pwd }
        in
        {
          conference;
          role =
            (if speaking then Speaker { tracks = [] }
             else Attendee { forwards = [] });
          ice;
          dtls = Dtls.Server.create (Lazy.force dtls_config);
          srtp = None;
          srtp_sender = None;
          sender_ssrc = random_int32 ();
          cname = random_cname ();
          created = Unix.gettimeofday ();
        }
  in
  (* What each section carries, for us to send on or to receive on. A repeat
     offer keeps the tracks it already has: an attendee whose stream changed
     source under it would see the change as loss. *)
  let sending =
    match session.role with
    | Speaker speaker ->
        speaker.tracks <-
          List.filter_map
            (fun (media, kind, codec) ->
              match (kind, codec) with
              | Some kind, Some codec ->
                  Some
                    (match
                       List.find_opt
                         (fun (track : incoming) ->
                           track.kind = kind && track.codec = codec)
                         speaker.tracks
                     with
                    | Some track -> { track with declared = media.Sdp.ssrcs }
                    | None -> incoming_of_media ~kind ~codec media)
              | _ -> None)
            chosen;
        fun _ -> None
    | Attendee attendee ->
        let forwards =
          List.filter_map
            (fun ((media : Sdp.media), kind, codec) ->
              match (kind, codec) with
              | Some kind, Some (codec : Sdp.codec) ->
                  let forward =
                    match
                      List.find_opt
                        (fun forward ->
                          forward.kind = kind
                          && forward.payload_type = codec.payload_type)
                        attendee.forwards
                    with
                    | Some forward -> forward
                    | None -> forward_of_codec ~kind ~codec
                  in
                  Some (media.mid, forward)
              | _ -> None)
            chosen
        in
        attendee.forwards <- List.map snd forwards;
        fun (media : Sdp.media) ->
          Option.map
            (fun forward ->
              {
                Sdp.ssrc = forward.out_ssrc;
                cname = session.cname;
                (* The microphone and the camera share a stream, which is
                   what asks a browser to play them in step; the desktop is a
                   stream of its own. Named after the CNAME rather than the
                   ICE fragment, which may hold a "/" — not one of the
                   characters an identifier here is made of (RFC 8830). *)
                stream =
                  (match forward.kind with
                  | Audio | Camera -> session.cname ^ "-speaker"
                  | Screen -> session.cname ^ "-screen");
                track = string_of_kind forward.kind;
              })
            (List.assoc_opt media.mid forwards)
  in
  let local = Ice.Agent.local session.ice in
  let answer =
    Sdp.answer ~offer ~media ~sending ~addresses:!advertised_ips
      ~port:!media_port ~ice_ufrag:local.ufrag ~ice_pwd:local.pwd
      ~fingerprint:("sha-256", (Lazy.force certificate).fingerprint)
      ()
  in
  (session, answer)

(* Feedback ---------------------------------------------------------------- *)

let send socket ~destination datagram =
  let datagram = Bytes.unsafe_of_string datagram in
  let%lwt _ =
    Lwt_unix.sendto socket datagram 0 (Bytes.length datagram) [] destination
  in
  Lwt.return_unit

(* A datagram sent from within the media path, where there is no Lwt thread to
   sequence it into. Nothing depends on when it leaves, or on its leaving at
   all: a lost keyframe request is asked again a moment later. *)
let send_async socket ~destination datagram =
  Lwt.async (fun () -> send socket ~destination datagram)

let send_rtcp socket session packet =
  match (session.srtp_sender, Ice.Agent.peer session.ice) with
  | Some sender, Some destination ->
      send_async socket ~destination (Srtp.protect_rtcp sender packet)
  | _ -> ()

(* How often a keyframe may be asked for. A request costs the speaker a whole
   picture, and a room full of attendees joining at once would otherwise ask
   for one each. *)
let pli_interval = 0.5

(* A browser sends a fresh keyframe only when asked (RFC 4585 §6.3.1), and
   until it does, an attendee that has just joined has nothing it can decode
   and one that lost a packet has nothing it can trust. *)
let request_keyframe socket conference (track : incoming) ~now =
  match (conference.speaker, track.ssrc) with
  | Some speaker, Some ssrc when now -. track.asked_at > pli_interval ->
      track.asked_at <- now;
      send_rtcp socket speaker
        (Rtp.Rtcp.pli ~sender:speaker.sender_ssrc ~media:ssrc);
      log.debug (fun log ->
          log "conference %S: asked for a %s keyframe" conference.name
            (string_of_kind track.kind))
  | _ -> ()

let request_keyframes socket conference =
  let now = Unix.gettimeofday () in
  match conference.speaker with
  | Some { role = Speaker speaker; _ } ->
      List.iter
        (fun (track : incoming) ->
          if track.format <> None then
            request_keyframe socket conference track ~now)
        speaker.tracks
  | _ -> ()

(* Forwarding -------------------------------------------------------------- *)

(* Sequence numbers are sixteen bits and wrap; "later" is the shorter way
   round (RFC 3550 §A.1). *)
let ahead sequence highest = (sequence - highest) land 0xffff < 32768

(* Everything an attendee's stream owes to the speaker's is a pair of offsets.
   They are fixed when forwarding starts, and again if the speaker's source
   changes under us, so that a stream carries on where it left off rather than
   jumping — a jump in the numbering reads as loss, and a jump in the clock as
   a gap to wait through. *)
let rebase forward (packet : Rtp.Packet.t) =
  forward.source <- Some packet.ssrc;
  forward.sequence_offset <- (forward.highest + 1 - packet.sequence) land 0xffff;
  (* A tenth of a second between what was sent and what follows it: enough for
     a receiver to see a new picture rather than a repeated one, little enough
     not to be a pause. *)
  forward.timestamp_offset <-
    Int32.sub
      (Int32.add forward.timestamp (Int32.of_int (forward.clock_rate / 10)))
      packet.timestamp;
  forward.started <- true

let forward_packet socket session forward (packet : Rtp.Packet.t) =
  match (session.srtp_sender, Ice.Agent.peer session.ice) with
  | Some sender, Some destination ->
      let packet =
        {
          packet with
          payload_type = forward.payload_type;
          ssrc = forward.out_ssrc;
          sequence = (packet.sequence + forward.sequence_offset) land 0xffff;
          timestamp = Int32.add packet.timestamp forward.timestamp_offset;
          (* Neither survives: no contributing sources are ours to name, and
             no header extension was negotiated with this peer. *)
          csrc = [];
          extension = None;
        }
      in
      if ahead packet.sequence forward.highest then begin
        forward.highest <- packet.sequence;
        forward.timestamp <- packet.timestamp
      end;
      forward.packets <- Int32.add forward.packets 1l;
      forward.octets <-
        Int32.add forward.octets (Int32.of_int (String.length packet.payload));
      send_async socket ~destination
        (Srtp.protect sender (Rtp.Packet.encode packet))
  | _ -> ()

(* One packet of the speaker's, to everyone watching. *)
let forward socket conference (track : incoming) packet =
  List.iter
    (fun session ->
      match session.role with
      (* Until the handshake with this attendee has finished there is nothing
         to protect its packets with, and the point it would have joined at
         must not be spent on packets that cannot leave. *)
      | _ when Option.is_none session.srtp_sender -> ()
      | Speaker _ -> ()
      | Attendee attendee -> (
          match
            List.find_opt (fun forward -> forward.kind = track.kind)
              attendee.forwards
          with
          | None -> ()
          | Some forward ->
              (* A source that changed is a speaker that reconnected: the
                 stream has to be picked up again from a picture that stands
                 on its own. *)
              if forward.source <> Some packet.Rtp.Packet.ssrc then begin
                forward.started <- false;
                forward.source <- Some packet.ssrc
              end;
              let joinable =
                match forward.format with
                (* Audio has no keyframes and needs none: a packet lost or
                   skipped costs its own duration and nothing more. *)
                | None -> true
                | Some format ->
                    Rtp.Frame.starts_keyframe format packet.payload
              in
              if forward.started then forward_packet socket session forward packet
              else if joinable then begin
                rebase forward packet;
                log.debug (fun log ->
                    log "session %s: %s starts at sequence %d" (ufrag session)
                      (string_of_kind forward.kind) forward.highest);
                forward_packet socket session forward packet
              end
              else
                (* Nothing can be sent to this attendee until the speaker
                   produces a picture that stands on its own. *)
                request_keyframe socket conference track
                  ~now:(Unix.gettimeofday ())))
    conference.attendees

(* Receiving from the speaker ---------------------------------------------- *)

(* Which track a packet belongs to. The offer says, when it declared its
   sources; when it did not, the payload type narrows it to a kind and the
   first track of that kind still waiting for a source takes it. *)
let track_of_packet speaker (packet : Rtp.Packet.t) =
  match
    List.find_opt
      (fun (track : incoming) -> track.ssrc = Some packet.ssrc)
      speaker.tracks
  with
  | Some track -> Some track
  | None -> (
      let unbound =
        List.filter
          (fun (track : incoming) ->
            track.ssrc = None && track.codec.payload_type = packet.payload_type)
          speaker.tracks
      in
      match
        List.find_opt
          (fun (track : incoming) -> List.mem packet.ssrc track.declared)
          unbound
      with
      | Some track -> Some track
      | None -> ( match unbound with track :: _ -> Some track | [] -> None))

let handle_speaker_rtp socket session speaker (packet : Rtp.Packet.t) =
  match track_of_packet speaker packet with
  | None ->
      (* Comfort noise, retransmissions, redundancy and the codecs we turned
         down all arrive on payload types of their own. *)
      log.debug (fun log ->
          log "ignoring payload type %d from %lx" packet.payload_type packet.ssrc)
  | Some track ->
      if track.ssrc <> Some packet.ssrc then begin
        track.ssrc <- Some packet.ssrc;
        track.reception <- Rtp.Reception.create ~clock_rate:track.codec.clock_rate;
        track.highest <- None;
        log.info (fun log ->
            log "conference %S: %s arriving as %lx" session.conference.name
              (string_of_kind track.kind) packet.ssrc)
      end;
      track.arrived <- Unix.gettimeofday ();
      Rtp.Reception.receive track.reception packet;
      (* A gap means every picture predicted from the one it ruined is ruined
         too, for every attendee at once, so the keyframe is asked for here
         rather than per attendee. *)
      (match track.highest with
      | Some highest
        when track.format <> None
             && ahead packet.sequence highest
             && (packet.sequence - highest) land 0xffff > 1 ->
          log.debug (fun log ->
              log "conference %S: %s lost %d packet(s)" session.conference.name
                (string_of_kind track.kind)
                (((packet.sequence - highest) land 0xffff) - 1));
          request_keyframe socket session.conference track
            ~now:(Unix.gettimeofday ())
      | _ -> ());
      if
        match track.highest with
        | None -> true
        | Some highest -> ahead packet.sequence highest
      then track.highest <- Some packet.sequence;
      forward socket session.conference track packet

let handle_speaker_rtcp conference speaker packet =
  List.iter
    (fun (info : Rtp.Rtcp.sender_info) ->
      List.iter
        (fun track ->
          if track.ssrc = Some info.sender then begin
            (* Echoed back in our reports, so that the speaker can measure a
               round trip... *)
            Rtp.Reception.sender_report track.reception
              ~ntp:(Rtp.Rtcp.compact_ntp info.ntp);
            (* ...and kept, because the pairing of the two clocks in it is
               what our own reports downstream have to reproduce. *)
            track.clock <- Some (Unix.gettimeofday (), info)
          end)
        speaker.tracks)
    (Rtp.Rtcp.sender_reports packet);
  log.debug (fun log ->
      log "conference %S: %d sender report(s)" conference.name
        (List.length (Rtp.Rtcp.sender_reports packet)))

(* Receiving from an attendee ---------------------------------------------- *)

let handle_attendee_rtcp socket session attendee packet =
  match Rtp.Rtcp.keyframe_requests packet with
  | [] -> ()
  | requests ->
      List.iter
        (fun ssrc ->
          match
            List.find_opt (fun forward -> forward.out_ssrc = ssrc)
              attendee.forwards
          with
          | None -> ()
          | Some forward -> (
              log.debug (fun log ->
                  log "session %s: asks for a %s keyframe" (ufrag session)
                    (string_of_kind forward.kind));
              match session.conference.speaker with
              | Some { role = Speaker speaker; _ } ->
                  List.iter
                    (fun (track : incoming) ->
                      if track.kind = forward.kind then
                        request_keyframe socket session.conference track
                          ~now:(Unix.gettimeofday ()))
                    speaker.tracks
              | _ -> ()))
        requests

(* Reports ----------------------------------------------------------------- *)

(* Due this often. RFC 3550 §6.2 would work the interval out from the session
   bandwidth and would not have it below five seconds, but the profile in use
   is AVPF, where a report may be as prompt as it is useful (RFC 4585 §3.4),
   and it is what a browser itself sends. *)
let report_interval = 1.

(* What arrived, told to the peer it arrived from: a sender that hears nothing
   about what got through has nothing to size its bitrate against, and cannot
   measure a round trip at all. *)
let report_to_speaker socket session speaker =
  match
    List.filter_map
      (fun (track : incoming) -> Rtp.Reception.report track.reception)
      speaker.tracks
  with
  | [] -> ()
  | reports ->
      send_rtcp socket session
        (Rtp.Rtcp.compound
           [
             Rtp.Rtcp.receiver_report ~sender:session.sender_ssrc reports;
             Rtp.Rtcp.source_description ~sender:session.sender_ssrc
               ~cname:session.cname;
           ])

(* What we are sending, told to the peer we are sending it to. Without it an
   attendee has two streams and no way to know they belong to one moment: the
   pairing of the stream's clock with the wall clock is the whole content of a
   sender report, and lip sync is what it buys.

   The pairing is the speaker's own, carried across: its reading advanced by
   however long ago it arrived, and its timestamp moved by the offset this
   attendee's stream was rebased on. Our own clock is used only to measure the
   interval, never to date the report, so the offset between the speaker's
   tracks survives even if our clock disagrees with its. *)
let report_to_attendee socket session attendee =
  match session.conference.speaker with
  | Some { role = Speaker speaker; _ } ->
      let now = Unix.gettimeofday () in
      let reports =
        List.filter_map
          (fun forward ->
            if not forward.started then None
            else
              match
                List.find_opt
                  (fun (track : incoming) -> track.kind = forward.kind)
                  speaker.tracks
              with
              | Some { clock = Some (at, info); _ } ->
                  let elapsed = now -. at in
                  let ntp =
                    Int64.add info.ntp
                      (Int64.of_float (elapsed *. 4294967296.))
                  in
                  let timestamp =
                    Int32.add
                      (Int32.add info.rtp_timestamp forward.timestamp_offset)
                      (Int32.of_float (elapsed *. float_of_int forward.clock_rate))
                  in
                  Some
                    (Rtp.Rtcp.sender_report ~sender:forward.out_ssrc ~ntp
                       ~timestamp ~packets:forward.packets
                       ~octets:forward.octets)
              (* Until the speaker has said what its clock reads there is
                 nothing to report that would not be a guess. *)
              | _ -> None)
          attendee.forwards
      in
      if reports <> [] then
        send_rtcp socket session
          (Rtp.Rtcp.compound
             (reports
             @ List.map
                 (fun forward ->
                   Rtp.Rtcp.source_description ~sender:forward.out_ssrc
                     ~cname:session.cname)
                 (List.filter (fun forward -> forward.started)
                    attendee.forwards)))
  | _ -> ()

(* The media socket -------------------------------------------------------- *)

(* Keep the address table in step with the agent, which latches and re-latches
   the peer address as checks arrive. *)
let track_peer session previous =
  if Ice.Agent.peer session.ice <> previous then begin
    Option.iter (fun address -> Hashtbl.remove sessions_by_peer address) previous;
    Option.iter
      (fun address ->
        Hashtbl.replace sessions_by_peer address session;
        log.info (fun log ->
            log "session %s latched onto %s" (ufrag session)
              (Ice.Agent.string_of_sockaddr address)))
      (Ice.Agent.peer session.ice)
  end

(* A STUN check names the session it belongs to through the local half of its
   USERNAME attribute. *)
let session_of_check datagram =
  match Ice.Stun.decode datagram with
  | Error _ -> None
  | Ok message -> (
      match Ice.Stun.username message with
      | None -> None
      | Some username -> (
          match String.index_opt username ':' with
          | None -> None
          | Some i -> Hashtbl.find_opt sessions (String.sub username 0 i)))

let handle_stun socket ~source datagram =
  match session_of_check datagram with
  | None ->
      log.debug (fun log ->
          log "STUN check for an unknown session from %s"
            (Ice.Agent.string_of_sockaddr source));
      Lwt.return_unit
  | Some session -> (
      let previous = Ice.Agent.peer session.ice in
      match Ice.Agent.handle session.ice ~source datagram with
      | Ice.Agent.Drop reason ->
          log.debug (fun log -> log "dropped a check: %s" reason);
          Lwt.return_unit
      | Ice.Agent.Respond response ->
          track_peer session previous;
          send socket ~destination:source response)

let handle_dtls socket ~source session datagram =
  let datagrams, event = Dtls.Server.handle session.dtls datagram in
  let%lwt () = Lwt_list.iter_s (send socket ~destination:source) datagrams in
  (match event with
  | Dtls.Server.Pending -> ()
  | Dtls.Server.Failed message ->
      (* A peer that closes the connection cleanly ends up here too, so this is
         where a session ends when the browser hangs up. *)
      log.warning (fun log ->
          log "session %s: DTLS ended: %s" (ufrag session) message);
      forget session
  | Dtls.Server.Established { profile = _; keying } ->
      (* The handshake keeps reporting itself established as the peer repeats
         its last flight; the keys are taken once. *)
      if session.srtp = None then begin
        session.srtp <-
          Some
            (Srtp.create ~master_key:keying.srtp_client_key
               ~master_salt:keying.srtp_client_salt);
        session.srtp_sender <-
          Some
            (Srtp.sender ~master_key:keying.srtp_server_key
               ~master_salt:keying.srtp_server_salt);
        log.info (fun log ->
            log "session %s: DTLS established, SRTP keys in hand"
              (ufrag session));
        (* An attendee that has just arrived can decode nothing until the
           speaker produces a picture that stands on its own. *)
        match session.role with
        | Attendee _ -> request_keyframes socket session.conference
        | Speaker _ -> ()
      end);
  Lwt.return_unit

let handle_media socket session datagram =
  match session.srtp with
  | None ->
      log.debug (fun log -> log "media before the SRTP keys were exchanged")
  | Some srtp -> (
      let rtcp = Rtp.Packet.is_rtcp datagram in
      let unprotect =
        if rtcp then Srtp.unprotect_rtcp srtp else Srtp.unprotect srtp
      in
      match unprotect datagram with
      | Error error ->
          log.warning (fun log ->
              log "session %s: %s" (ufrag session) (Srtp.string_of_error error))
      | Ok packet -> (
          match (rtcp, session.role) with
          | true, Speaker speaker ->
              handle_speaker_rtcp session.conference speaker packet
          | true, Attendee attendee ->
              handle_attendee_rtcp socket session attendee packet
          | false, Attendee _ ->
              (* An attendee is answered sendonly throughout and has nothing to
                 send us. *)
              log.debug (fun log ->
                  log "session %s: media from an attendee" (ufrag session))
          | false, Speaker speaker -> (
              match Rtp.Packet.parse packet with
              | exception Rtp.Packet.Invalid message ->
                  log.warning (fun log -> log "malformed RTP packet: %s" message)
              | packet -> handle_speaker_rtp socket session speaker packet)))

let handle_datagram socket ~source datagram =
  let session () = Hashtbl.find_opt sessions_by_peer source in
  match Char.code datagram.[0] with
  (* RFC 7983 demultiplexing. *)
  | b when b < 4 -> handle_stun socket ~source datagram
  | b when b >= 20 && b < 64 -> (
      match session () with
      | None ->
          log.debug (fun log -> log "DTLS from an unknown peer");
          Lwt.return_unit
      | Some session -> handle_dtls socket ~source session datagram)
  | b when b >= 128 && b < 192 ->
      (match session () with
      | None -> log.debug (fun log -> log "media from an unknown peer")
      | Some session -> handle_media socket session datagram);
      Lwt.return_unit
  | b ->
      log.debug (fun log -> log "unrecognised datagram starting with 0x%02x" b);
      Lwt.return_unit

let media_loop socket =
  (* Comfortably above the 1200-byte MTU WebRTC keeps to. *)
  let buffer = Bytes.create 2048 in
  let rec loop () =
    let%lwt length, source =
      Lwt_unix.recvfrom socket buffer 0 (Bytes.length buffer) []
    in
    let%lwt () =
      if length = 0 then Lwt.return_unit
      else
        try%lwt handle_datagram socket ~source (Bytes.sub_string buffer 0 length)
        with exn ->
          log.error (fun log ->
              log "while handling a datagram from %s: %s"
                (Ice.Agent.string_of_sockaddr source)
                (Printexc.to_string exn));
          Lwt.return_unit
    in
    loop ()
  in
  loop ()

(* Reports are the one thing here that is sent on a schedule rather than in
   answer to a datagram. *)
let rec report_loop socket =
  let%lwt () = Lwt_unix.sleep report_interval in
  Hashtbl.iter
    (fun _ session ->
      match session.role with
      | Speaker speaker -> report_to_speaker socket session speaker
      | Attendee attendee -> report_to_attendee socket session attendee)
    (Hashtbl.copy sessions);
  report_loop socket

(* Offers that never lead to a connection, and peers that go away without
   saying so, would otherwise accumulate. *)
let rec reap_sessions () =
  let%lwt () = Lwt_unix.sleep 10. in
  let now = Unix.gettimeofday () in
  Hashtbl.iter
    (fun key session ->
      if not (Ice.Agent.alive session.ice) then begin
        log.info (fun log ->
            log "forgetting session %s, idle, %.0fs old" key
              (now -. session.created));
        forget session
      end)
    (Hashtbl.copy sessions);
  reap_sessions ()

(* Signalling -------------------------------------------------------------- *)

(* Names that would otherwise be conferences. *)
let reserved = [ "static"; "favicon.ico"; "" ]

let handle_offer ~speaking request =
  let name = Dream.param request "conference" in
  if List.mem name reserved then Dream.respond ~status:`Not_Found "no such page"
  else
    let%lwt body = Dream.body request in
    let conference = conference name in
    let existing =
      match Dream.header request session_header with
      | None -> None
      | Some ufrag -> (
          match Hashtbl.find_opt sessions ufrag with
          (* A repeat offer is only ever for the session that made the first
             one, in the conference it was made in. *)
          | Some session when session.conference == conference -> Some session
          | _ -> None)
    in
    (* First speaker wins: a second is turned away for as long as the first is
       there, so that a conference cannot be taken over by anyone who knows its
       address. A repeat offer from the speaker itself is not a second.

       A peer refreshes consent every few seconds, so a shorter silence than
       the one the idle sweep waits out is enough to say that a speaker has
       gone: a browser that crashed must not hold a conference shut until the
       sweep comes round. *)
    let taken =
      match (conference.speaker, existing) with
      | None, _ -> false
      | Some current, Some session when current == session -> false
      | Some current, _ ->
          Ice.Agent.alive ~timeout:5. current.ice
          || (forget current;
              false)
    in
    if speaking && taken then begin
      log.warning (fun log ->
          log "conference %S: a second speaker was turned away" name);
      Dream.respond ~status:`Conflict "this conference already has a speaker"
    end
    else
      match Sdp.parse_offer body with
      | exception Sdp.Invalid message ->
          log.warning (fun log -> log "bad offer: %s" message);
          Dream.respond ~status:`Bad_Request message
      | offer ->
          let session, answer = negotiate ~conference ~speaking ~existing offer in
          if Option.is_none existing then begin
            Hashtbl.replace sessions (ufrag session) session;
            if speaking then conference.speaker <- Some session
            else conference.attendees <- session :: conference.attendees
          end;
          log.info (fun log ->
              log "conference %S: %s %s, %s" name
                (if speaking then "speaker" else "attendee")
                (ufrag session)
                (String.concat ", "
                   (match session.role with
                   | Speaker speaker ->
                       List.map
                         (fun (track : incoming) ->
                           Printf.sprintf "%s as %s/%d"
                             (string_of_kind track.kind) track.codec.name
                             track.codec.payload_type)
                         speaker.tracks
                   | Attendee attendee ->
                       List.map
                         (fun forward ->
                           Printf.sprintf "%s as %lx/%d"
                             (string_of_kind forward.kind) forward.out_ssrc
                             forward.payload_type)
                         attendee.forwards)));
          log.debug (fun log -> log "answer:\n%s" answer);
          Dream.respond
            ~headers:
              [
                ("Content-Type", "application/sdp");
                (session_header, ufrag session);
              ]
            answer

let handle_stop request =
  match Dream.header request session_header with
  | None -> Dream.respond ~status:`Bad_Request "no session given"
  | Some ufrag -> (
      match Hashtbl.find_opt sessions ufrag with
      | None -> Dream.respond ~status:`Not_Found "no such session"
      | Some session ->
          log.info (fun log -> log "session %s: stopped by the client" ufrag);
          forget session;
          Dream.respond "")

(* A track a page can be told about: one whose packets are still arriving.
   Nothing says that the desktop has stopped being shared — the track stays
   negotiated and simply goes quiet — so silence is the test. *)
let live track = Unix.gettimeofday () -. track.arrived < 2.

let handle_status request =
  let name = Dream.param request "conference" in
  let speaking, sharing, attendees =
    match Hashtbl.find_opt conferences name with
    | None -> (false, false, 0)
    | Some conference ->
        ( Option.is_some conference.speaker,
          (match conference.speaker with
          | Some { role = Speaker speaker; _ } ->
              List.exists
                (fun (track : incoming) -> track.kind = Screen && live track)
                speaker.tracks
          | _ -> false),
          List.length conference.attendees )
  in
  Dream.respond
    ~headers:[ ("Content-Type", "application/json") ]
    (Printf.sprintf {|{"speaker":%b,"sharing":%b,"attendees":%d}|} speaking
       sharing attendees)

(* Entry point ------------------------------------------------------------- *)

let bind_address () =
  match (!bind_ip, !advertised_ips) with
  | Some address, _ -> address
  | None, [ address ] -> address
  | None, _ -> "0.0.0.0"

let media_socket () =
  let socket = Lwt_unix.socket PF_INET SOCK_DGRAM 0 in
  Lwt_unix.setsockopt socket SO_REUSEADDR true;
  Lwt_unix.bind socket
    (Unix.ADDR_INET (Unix.inet_addr_of_string (bind_address ()), !media_port))
  |> Lwt.map (fun () -> socket)

let page name request = Dream.from_filesystem !static_root name request

let () =
  Arg.parse
    [
      ("--port", Arg.Set_int http_port, "PORT  HTTP port (default 8080)");
      ( "--interface",
        Arg.Set_string http_interface,
        "ADDRESS  interface the HTTP server binds to (default localhost, use \
         0.0.0.0 to accept connections from other machines)" );
      ("--media-port", Arg.Set_int media_port, "PORT  UDP port for media (default 7000)");
      ("--debug", Arg.Set debug, "  log every datagram that is dropped");
      ( "--static",
        Arg.Set_string static_root,
        "DIRECTORY  the directory the pages are served from (default \
         examples/conference/static)" );
      ( "--bind",
        Arg.String (fun address -> bind_ip := Some address),
        "ADDRESS  local address the media socket binds to, when it differs \
         from the advertised one (behind a NAT, say)" );
      ( "--ip",
        Arg.String (fun address -> advertised_ips := !advertised_ips @ [ address ]),
        "ADDRESS  an address to advertise as an ICE candidate, which must be \
         reachable by the browser; may be repeated, most preferred first \
         (default: this machine's own addresses)" );
    ]
    (fun argument -> raise (Arg.Bad ("unexpected argument: " ^ argument)))
    "conference [options]";
  if !advertised_ips = [] then advertised_ips := default_addresses ();
  Dream.initialize_log ~level:(if !debug then `Debug else `Info) ();
  (* The sub-log keeps the threshold it was created with, so it needs telling
     separately. *)
  if !debug then Dream.set_log_level "conference" `Debug;
  Mirage_crypto_rng_unix.use_default ();
  log.info (fun log ->
      log "certificate fingerprint %s" (Lazy.force certificate).fingerprint);
  Lwt.async (fun () ->
      let%lwt socket = media_socket () in
      log.info (fun log ->
          log "media socket listening on %s:%d, advertising %s" (bind_address ())
            !media_port
            (String.concat ", " !advertised_ips));
      Lwt.async (fun () -> report_loop socket);
      media_loop socket);
  Lwt.async reap_sessions;
  Dream.run ~interface:!http_interface ~port:!http_port
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.get "/" (page "index.html");
         Dream.get "/static/**" (Dream.static !static_root);
         (* Before the conference routes, which would otherwise take them for
            conference names. *)
         Dream.post "/:conference/offer" (handle_offer ~speaking:false);
         Dream.post "/:conference/speaker/offer" (handle_offer ~speaking:true);
         Dream.post "/:conference/stop" handle_stop;
         Dream.get "/:conference/status" handle_status;
         Dream.get "/:conference/speaker" (page "speaker.html");
         Dream.get "/:conference" (page "attendee.html");
       ]

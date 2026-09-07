type codec = Vp8 | Vp9 | H264

type frame = { timestamp : int32; keyframe : bool; data : string }

type pending = {
  timestamp : int32;
  data : Buffer.t;
  mutable keyframe : bool;
  (* Set when a packet is missing, or when the first packet seen for this
     timestamp was not the one that starts the picture. *)
  mutable damaged : bool;
}

type t = {
  codec : codec;
  h264 : H264.t;
  mutable current : pending option;
  mutable expected : int option;  (** the next sequence number in order *)
  mutable sps : string option;
  mutable pps : string option;
  mutable dimensions : (int * int) option;
  mutable dropped : int;
}

let create codec =
  {
    codec;
    h264 = H264.create ();
    current = None;
    expected = None;
    sps = None;
    pps = None;
    dimensions = None;
    dropped = 0;
  }

(* Where a receiver may join --------------------------------------------- *)

(* A picture that can be decoded on its own, and the beginning of it: a
   forwarder that starts anywhere else sends its peer packets it can only
   throw away, or worse, decode into a picture built on frames it never had.

   VP8 and VP9 carry the frame type in the frame's own first bytes, so the
   packet that starts the frame is both the test and the place to start. H.264
   keeps the parameter sets out of the picture, and a decoder that joins at the
   IDR without them has nothing to configure itself from; a browser sends them
   immediately before, so the sequence parameter set is the point to join. *)
let starts_keyframe codec payload =
  match codec with
  | Vp8 ->
      Vp8.starts_frame payload
      && (match Vp8.partition payload with
         | data -> Vp8.keyframe data
         | exception Vp8.Invalid _ -> false)
  | Vp9 ->
      Vp9.starts_frame payload
      && (match Vp9.payload payload with
         | data -> Vp9.keyframe data
         | exception Vp9.Invalid _ -> false)
  | H264 -> List.mem 7 (H264.payload_nal_types payload)

let dimensions t = t.dimensions
let dropped t = t.dropped

let parameter_sets t =
  match (t.sps, t.pps) with Some sps, Some pps -> Some (sps, pps) | _ -> None

let starts_frame t payload =
  match t.codec with
  | Vp8 -> Vp8.starts_frame payload
  | Vp9 -> Vp9.starts_frame payload
  | H264 -> H264.starts_unit payload

(* What a payload adds to the picture being assembled. *)
let append t pending payload =
  match t.codec with
  | Vp8 -> (
      match Vp8.partition payload with
      | exception Vp8.Invalid _ -> pending.damaged <- true
      | partition -> Buffer.add_string pending.data partition)
  | Vp9 -> (
      match Vp9.payload payload with
      | exception Vp9.Invalid _ -> pending.damaged <- true
      | data -> Buffer.add_string pending.data data)
  | H264 ->
      List.iter
        (fun nal ->
          (match H264.nal_type nal with
          | 5 -> pending.keyframe <- true
          | 7 ->
              if t.sps = None then begin
                t.sps <- Some nal;
                if t.dimensions = None then t.dimensions <- H264.dimensions nal
              end
          | 8 -> if t.pps = None then t.pps <- Some nal
          | _ -> ());
          (* The parameter sets stay in the stream as well as going into the
             container's own header: a browser resends them before every
             keyframe, and one that changes mid-recording would otherwise be
             lost. *)
          Buffer.add_string pending.data (H264.length_prefixed nal))
        (H264.push t.h264 payload)

(* A picture is finished: emit it, unless a packet of it went missing. *)
let finish t =
  match t.current with
  | None -> []
  | Some pending ->
      t.current <- None;
      let data = Buffer.contents pending.data in
      if pending.damaged || data = "" then begin
        t.dropped <- t.dropped + 1;
        []
      end
      else
        let keyframe =
          match t.codec with
          | Vp8 -> Vp8.keyframe data
          | Vp9 -> Vp9.keyframe data
          | H264 -> pending.keyframe
        in
        (* H.264 is the exception: its size comes out of a parameter set as it
           goes by, not out of the picture. *)
        if keyframe && t.dimensions = None then
          (match t.codec with
          | Vp8 -> t.dimensions <- Vp8.dimensions data
          | Vp9 -> t.dimensions <- Vp9.dimensions data
          | H264 -> ());
        [ { timestamp = pending.timestamp; keyframe; data } ]

let push t (packet : Packet.t) =
  (* A gap in the numbering means a lost packet: the picture it belonged to
     cannot be completed, and a half-received fragment inside it is equally
     beyond saving. *)
  let discontinuity =
    match t.expected with Some expected -> packet.sequence <> expected | None -> false
  in
  t.expected <- Some ((packet.sequence + 1) land 0xffff);
  if discontinuity then begin
    Option.iter (fun pending -> pending.damaged <- true) t.current;
    H264.reset t.h264
  end;
  (* A new timestamp starts a new picture; the one before it never saw its
     marker bit, so it was truncated and finishing it only counts the loss. *)
  (match t.current with
  | Some pending when pending.timestamp <> packet.timestamp ->
      pending.damaged <- true;
      ignore (finish t)
  | _ -> ());
  if t.current = None then
    t.current <-
      Some
        {
          timestamp = packet.timestamp;
          data = Buffer.create 4096;
          keyframe = false;
          damaged = (not (starts_frame t packet.payload)) || discontinuity;
        };
  (match t.current with
  | Some pending -> append t pending packet.payload
  | None -> ());
  if packet.marker then finish t else []

let flush t =
  match t.current with
  | None -> []
  | Some pending ->
      (* No marker bit ever arrived, so the picture is short of its tail. *)
      pending.damaged <- true;
      finish t

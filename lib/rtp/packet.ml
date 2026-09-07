(** RTP packets (RFC 3550 §5.1) and the RTP/RTCP distinction.

    Only what a receiver needs to read: the fields that identify a stream and
    order it, and the boundary between the header and the payload, which is
    also the boundary SRTP encrypts from. A forwarder writes some of them back
    out, which is what {!encode} is for. *)

type t = {
  padding : bool;
  marker : bool;
  payload_type : int;
  sequence : int;
  timestamp : int32;
  ssrc : int32;
  csrc : int32 list;
  extension : (int * string) option;  (** profile identifier and its data *)
  payload : string;
  header_length : int;
      (** the header, its CSRC list and any extension: the offset at which the
          payload, and the part SRTP encrypts, begins *)
}

let version = 2
let minimum_header_length = 12

exception Invalid of string

let invalid fmt = Printf.ksprintf (fun message -> raise (Invalid message)) fmt

(** How many leading bytes of a packet are header. Kept separate from parsing
    because SRTP must know it before it can decrypt what follows. *)
let header_length packet =
  let length = String.length packet in
  if length < minimum_header_length then invalid "packet shorter than a header";
  let first = Char.code packet.[0] in
  if first lsr 6 <> version then invalid "not an RTP version 2 packet";
  let csrc_count = first land 0x0f in
  let extension = first land 0x10 <> 0 in
  let after_csrc = minimum_header_length + (4 * csrc_count) in
  if not extension then
    if length < after_csrc then invalid "truncated CSRC list" else after_csrc
  else if length < after_csrc + 4 then invalid "truncated header extension"
  else
    (* A header extension is a 16-bit profile, a 16-bit length in 32-bit words,
       then that many words. *)
    let words = String.get_uint16_be packet (after_csrc + 2) in
    let total = after_csrc + 4 + (4 * words) in
    if length < total then invalid "truncated header extension" else total

let parse packet =
  let header_length = header_length packet in
  let first = Char.code packet.[0] in
  let second = Char.code packet.[1] in
  let csrc_count = first land 0x0f in
  {
    padding = first land 0x20 <> 0;
    marker = second land 0x80 <> 0;
    payload_type = second land 0x7f;
    sequence = String.get_uint16_be packet 2;
    timestamp = String.get_int32_be packet 4;
    ssrc = String.get_int32_be packet 8;
    csrc =
      List.init csrc_count (fun i ->
          String.get_int32_be packet (minimum_header_length + (4 * i)));
    extension =
      (if first land 0x10 = 0 then None
       else
         let after_csrc = minimum_header_length + (4 * csrc_count) in
         Some
           ( String.get_uint16_be packet after_csrc,
             String.sub packet (after_csrc + 4) (header_length - after_csrc - 4) ));
    payload =
      String.sub packet header_length (String.length packet - header_length);
    header_length;
  }

(** The packet a description stands for. [header_length] is ignored: it
    describes the packet a value was parsed from, and a value that has been
    altered since — as a forwarder alters the source and the numbering —
    describes a packet of its own. *)
let encode packet =
  let csrc_count = List.length packet.csrc in
  if csrc_count > 15 then invalid "more than fifteen contributing sources";
  let extension_words =
    match packet.extension with
    | None -> 0
    | Some (_, data) ->
        if String.length data land 3 <> 0 then
          invalid "a header extension is a whole number of words";
        String.length data / 4
  in
  let header_length =
    minimum_header_length + (4 * csrc_count)
    + (match packet.extension with None -> 0 | Some _ -> 4 + (4 * extension_words))
  in
  let header = Bytes.create header_length in
  Bytes.set_uint8 header 0
    ((version lsl 6)
    lor (if packet.padding then 0x20 else 0)
    lor (match packet.extension with None -> 0 | Some _ -> 0x10)
    lor csrc_count);
  Bytes.set_uint8 header 1
    ((if packet.marker then 0x80 else 0) lor (packet.payload_type land 0x7f));
  Bytes.set_uint16_be header 2 (packet.sequence land 0xffff);
  Bytes.set_int32_be header 4 packet.timestamp;
  Bytes.set_int32_be header 8 packet.ssrc;
  List.iteri
    (fun i source ->
      Bytes.set_int32_be header (minimum_header_length + (4 * i)) source)
    packet.csrc;
  (match packet.extension with
  | None -> ()
  | Some (profile, data) ->
      let after_csrc = minimum_header_length + (4 * csrc_count) in
      Bytes.set_uint16_be header after_csrc profile;
      Bytes.set_uint16_be header (after_csrc + 2) extension_words;
      Bytes.blit_string data 0 header (after_csrc + 4) (String.length data));
  Bytes.unsafe_to_string header ^ packet.payload

(** RTP and RTCP share a port when [a=rtcp-mux] is negotiated; they are told
    apart by the payload type field, RTCP's packet types all falling in
    64..95 once the marker bit is included (RFC 5761 §4). *)
let is_rtcp packet =
  String.length packet >= 2
  &&
  let payload_type = Char.code packet.[1] land 0x7f in
  payload_type >= 64 && payload_type <= 95

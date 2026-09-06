(** SRTP (RFC 3711) for the one profile DTLS-SRTP negotiates with browsers,
    [AES_CM_128_HMAC_SHA1_80]: AES-128 in counter mode for confidentiality and
    an 80-bit HMAC-SHA1 tag for authentication.

    Media is received and, by a forwarder, sent on again, so both halves are
    here. Each synchronisation source is tracked separately, as each has its
    own rollover counter and replay window. *)

module Aes = Mirage_crypto.AES.CTR

type error =
  | Too_short
  | Malformed of string
  | Authentication_failed
  | Replayed

let string_of_error = function
  | Too_short -> "packet too short"
  | Malformed message -> message
  | Authentication_failed -> "authentication failed"
  | Replayed -> "replayed or too old"

let tag_length = 10
let salt_length = 14
let key_length = 16
let auth_key_length = 20

(* Key derivation (RFC 3711 §4.3.1) ---------------------------------------- *)

module Label = struct
  let rtp_encryption = 0
  let rtp_authentication = 1
  let rtp_salt = 2
  let rtcp_encryption = 3
  let rtcp_authentication = 4
  let rtcp_salt = 5
end

(** The key derivation function: AES in counter mode under the master key, with
    the label exclusive-ored into the master salt. The key derivation rate is
    zero, as DTLS-SRTP leaves it, so [index DIV rate] is zero and the input
    depends on the label alone. *)
let derive ~master_key ~master_salt ~label length =
  let input = Bytes.of_string master_salt in
  (* The label is the least significant byte of the seven-octet key
     identifier, right-aligned against the fourteen-octet salt. *)
  Bytes.set input 7 (Char.chr (Char.code (Bytes.get input 7) lxor label));
  let counter = Bytes.to_string input ^ "\000\000" (* multiply by 2^16 *) in
  Aes.stream
    ~key:(Aes.of_secret master_key)
    ~ctr:(Aes.ctr_of_octets counter) length

type keys = { cipher : Aes.key; authentication : string; salt : string }

let derive_keys ~master_key ~master_salt ~encryption ~authentication ~salt =
  {
    cipher =
      Aes.of_secret (derive ~master_key ~master_salt ~label:encryption key_length);
    authentication =
      derive ~master_key ~master_salt ~label:authentication auth_key_length;
    salt = derive ~master_key ~master_salt ~label:salt salt_length;
  }

(* Per-source state -------------------------------------------------------- *)

type stream = {
  mutable roc : int;  (** rollover counter: how often the sequence wrapped *)
  mutable highest : int;  (** highest sequence number authenticated so far *)
  mutable window : int64;  (** the 64 packets before [highest] *)
  mutable seen : bool;
}

type t = {
  rtp : keys;
  rtcp : keys;
  streams : (int32, stream) Hashtbl.t;
  rtcp_replay : (int32, int) Hashtbl.t;
}

let create ~master_key ~master_salt =
  if String.length master_key <> key_length then
    invalid_arg "Srtp.create: the master key must be 16 bytes";
  if String.length master_salt <> salt_length then
    invalid_arg "Srtp.create: the master salt must be 14 bytes";
  {
    rtp =
      derive_keys ~master_key ~master_salt ~encryption:Label.rtp_encryption
        ~authentication:Label.rtp_authentication ~salt:Label.rtp_salt;
    rtcp =
      derive_keys ~master_key ~master_salt ~encryption:Label.rtcp_encryption
        ~authentication:Label.rtcp_authentication ~salt:Label.rtcp_salt;
    streams = Hashtbl.create 4;
    rtcp_replay = Hashtbl.create 4;
  }

let stream t ssrc =
  match Hashtbl.find_opt t.streams ssrc with
  | Some stream -> stream
  | None ->
      let stream = { roc = 0; highest = 0; window = 0L; seen = false } in
      Hashtbl.replace t.streams ssrc stream;
      stream

(** Which rollover counter a sequence number belongs to, given the highest one
    seen so far (RFC 3711 §3.3.1). A number far ahead of the highest is taken
    to be a straggler from before the last wrap, and one far behind to belong
    to the next. *)
let estimate_roc stream sequence =
  if not stream.seen then stream.roc
  else if stream.highest < 32768 then
    if sequence - stream.highest > 32768 then max 0 (stream.roc - 1)
    else stream.roc
  else if stream.highest - 32768 > sequence then stream.roc + 1
  else stream.roc

let index roc sequence = (roc * 65536) + sequence

(* A packet older than the window, or already seen within it, is a replay. *)
let fresh stream index_ =
  let highest = index stream.roc stream.highest in
  if not stream.seen then true
  else if index_ > highest then true
  else
    let age = highest - index_ in
    age < 64 && Int64.logand stream.window (Int64.shift_left 1L age) = 0L

let remember stream ~roc ~sequence ~index_ =
  let highest = index stream.roc stream.highest in
  if (not stream.seen) || index_ > highest then begin
    let shift = if stream.seen then index_ - highest else 0 in
    stream.window <-
      Int64.logor
        (if shift >= 64 then 0L else Int64.shift_left stream.window shift)
        1L;
    stream.roc <- roc;
    stream.highest <- sequence;
    stream.seen <- true
  end
  else
    stream.window <-
      Int64.logor stream.window (Int64.shift_left 1L (highest - index_))

(* Ciphering --------------------------------------------------------------- *)

(** The counter block of RFC 3711 §4.1.1: the session salt, the source and the
    packet index, each shifted into its own position. *)
let counter ~salt ~ssrc ~index =
  let block = Bytes.make 16 '\000' in
  Bytes.blit_string salt 0 block 0 salt_length;
  let xor offset value width =
    for i = 0 to width - 1 do
      let byte = (value lsr (8 * (width - 1 - i))) land 0xff in
      Bytes.set block (offset + i)
        (Char.chr (Char.code (Bytes.get block (offset + i)) lxor byte))
    done
  in
  xor 4 (Int32.to_int ssrc land 0xffffffff) 4;
  xor 8 index 6;
  Bytes.unsafe_to_string block

let cipher keys ~ssrc ~index ~data =
  Aes.encrypt ~key:keys.cipher
    ~ctr:(Aes.ctr_of_octets (counter ~salt:keys.salt ~ssrc ~index))
    data

(** Constant-time comparison of authentication tags. *)
let equal_tags a b =
  String.length a = String.length b
  && (let difference = ref 0 in
      String.iteri
        (fun i c -> difference := !difference lor (Char.code c lxor Char.code b.[i]))
        a;
      !difference = 0)

let authenticate ~key data =
  String.sub Digestif.SHA1.(to_raw_string (hmac_string ~key data)) 0 tag_length

(* Unprotecting ------------------------------------------------------------ *)

let split_tag packet =
  let length = String.length packet in
  if length < tag_length then None
  else
    Some
      (String.sub packet 0 (length - tag_length), String.sub packet (length - tag_length) tag_length)

(** Authenticate and decrypt an SRTP packet, yielding the RTP packet inside. *)
let unprotect t packet =
  match split_tag packet with
  | None -> Error Too_short
  | Some (body, tag) -> (
      match Rtp.Packet.header_length body with
      | exception Rtp.Packet.Invalid message -> Error (Malformed message)
      | header_length -> (
          let sequence = String.get_uint16_be body 2 in
          let ssrc = String.get_int32_be body 8 in
          let stream = stream t ssrc in
          let roc = estimate_roc stream sequence in
          let index_ = index roc sequence in
          if not (fresh stream index_) then Error Replayed
          else
            (* The rollover counter is authenticated with the packet, though it
               travels only in the receiver's own state. *)
            let roll = Bytes.create 4 in
            Bytes.set_int32_be roll 0 (Int32.of_int roc);
            let expected =
              authenticate ~key:t.rtp.authentication
                (body ^ Bytes.unsafe_to_string roll)
            in
            if not (equal_tags tag expected) then Error Authentication_failed
            else
              (* Everything after the header, extension included, is encrypted;
                 the header itself travels in the clear. *)
              let header = String.sub body 0 header_length in
              let payload =
                String.sub body header_length (String.length body - header_length)
              in
              let payload = cipher t.rtp ~ssrc ~index:index_ ~data:payload in
              remember stream ~roc ~sequence ~index_;
              Ok (header ^ payload)))

(** The same for SRTCP, whose index travels in the packet itself, in a trailing
    word whose top bit says whether the packet was encrypted (RFC 3711 §3.4). *)
let unprotect_rtcp t packet =
  match split_tag packet with
  | None -> Error Too_short
  | Some (body, tag) ->
      let length = String.length body in
      if length < 12 then Error Too_short
      else
        let trailer = String.get_int32_be body (length - 4) in
        let encrypted = Int32.logand trailer 0x80000000l <> 0l in
        let index = Int32.to_int (Int32.logand trailer 0x7fffffffl) in
        let ssrc = String.get_int32_be body 4 in
        let expected = authenticate ~key:t.rtcp.authentication body in
        if not (equal_tags tag expected) then Error Authentication_failed
        else if
          match Hashtbl.find_opt t.rtcp_replay ssrc with
          | Some highest -> index <= highest
          | None -> false
        then Error Replayed
        else begin
          Hashtbl.replace t.rtcp_replay ssrc index;
          (* The first two words, up to and including the sender's identifier,
             are authenticated but not encrypted. *)
          let header = String.sub body 0 8 in
          let payload = String.sub body 8 (length - 8 - 4) in
          let payload =
            if encrypted then cipher t.rtcp ~ssrc ~index ~data:payload
            else payload
          in
          Ok (header ^ payload)
        end

(* Protecting -------------------------------------------------------------- *)

type sender = {
  rtp_keys : keys;
  keys : keys;  (** RTCP's, named as it was when they were the only ones *)
  mutable rtcp_index : int;
  (* The rollover counter of each source we send under. It is not carried by a
     packet, so both ends count the wraps for themselves; ours has to agree
     with what the receiver will infer from the sequence numbers. *)
  sent : (int32, stream) Hashtbl.t;
}

let sender ~master_key ~master_salt =
  if String.length master_key <> key_length then
    invalid_arg "Srtp.sender: the master key must be 16 bytes";
  if String.length master_salt <> salt_length then
    invalid_arg "Srtp.sender: the master salt must be 14 bytes";
  {
    rtp_keys =
      derive_keys ~master_key ~master_salt ~encryption:Label.rtp_encryption
        ~authentication:Label.rtp_authentication ~salt:Label.rtp_salt;
    keys =
      derive_keys ~master_key ~master_salt ~encryption:Label.rtcp_encryption
        ~authentication:Label.rtcp_authentication ~salt:Label.rtcp_salt;
    rtcp_index = 0;
    sent = Hashtbl.create 4;
  }

(** Protect an RTP packet. The rollover counter is estimated exactly as the
    receiver will estimate it, from the sequence numbers gone before, so that
    a packet sent out of order — which a forwarder does whenever the network
    reordered what it was given — is numbered the way its own sequence number
    says rather than the way its turn says. *)
let protect t packet =
  match Rtp.Packet.header_length packet with
  | exception Rtp.Packet.Invalid message ->
      invalid_arg ("Srtp.protect: " ^ message)
  | header_length ->
      let sequence = String.get_uint16_be packet 2 in
      let ssrc = String.get_int32_be packet 8 in
      let stream =
        match Hashtbl.find_opt t.sent ssrc with
        | Some stream -> stream
        | None ->
            let stream = { roc = 0; highest = 0; window = 0L; seen = false } in
            Hashtbl.replace t.sent ssrc stream;
            stream
      in
      let roc = estimate_roc stream sequence in
      let index_ = index roc sequence in
      if (not stream.seen) || index_ > index stream.roc stream.highest then begin
        stream.roc <- roc;
        stream.highest <- sequence;
        stream.seen <- true
      end;
      let header = String.sub packet 0 header_length in
      let payload =
        String.sub packet header_length (String.length packet - header_length)
      in
      let body =
        header ^ cipher t.rtp_keys ~ssrc ~index:index_ ~data:payload
      in
      let roll = Bytes.create 4 in
      Bytes.set_int32_be roll 0 (Int32.of_int roc);
      body
      ^ authenticate ~key:t.rtp_keys.authentication
          (body ^ Bytes.unsafe_to_string roll)

(* The index is ours to choose and must never repeat under one key, since it is
   what makes each counter block unique. Thirty-one bits at a handful of
   packets a second is not a bound anything reaches. *)
let protect_rtcp t packet =
  if String.length packet < 8 then invalid_arg "Srtp.protect_rtcp: not an RTCP packet";
  let index = t.rtcp_index in
  t.rtcp_index <- (index + 1) land 0x7fffffff;
  let ssrc = String.get_int32_be packet 4 in
  (* As on the receiving side, the first two words travel in the clear. *)
  let header = String.sub packet 0 8 in
  let payload =
    cipher t.keys ~ssrc ~index ~data:(String.sub packet 8 (String.length packet - 8))
  in
  let trailer = Bytes.create 4 in
  (* The top bit says the packet is encrypted (RFC 3711 §3.4). *)
  Bytes.set_int32_be trailer 0 (Int32.logor 0x80000000l (Int32.of_int index));
  let body = header ^ payload ^ Bytes.unsafe_to_string trailer in
  body ^ authenticate ~key:t.keys.authentication body

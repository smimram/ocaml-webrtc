(** RFC 3711 test vectors, plus the sequence-number bookkeeping around them. *)

open Testlib

let master_key = hex "E1F97A0D3E018BE0D64FA32C06DE4139"
let master_salt = hex "0EC675AD498AFEEBB6960B3AABE6"

(* §B.2: the counter block and keystream for a session key and salt. *)
let session_key = hex "2B7E151628AED2A6ABF7158809CF4F3C"
let session_salt = hex "F0F1F2F3F4F5F6F7F8F9FAFBFCFD"

let keystream ~length =
  let keys =
    {
      Srtp.cipher = Mirage_crypto.AES.CTR.of_secret session_key;
      authentication = "";
      salt = session_salt;
    }
  in
  (* Counter mode over zeroes is the keystream itself. *)
  Srtp.cipher keys ~ssrc:0l ~index:0 ~data:(String.make length '\000')

let run () =
  suite "srtp";

  (* §B.3: key derivation *)
  check_string "cipher key"
    ~expected:(hex "C61E7A93744F39EE10734AFE3FF7A087")
    (Srtp.derive ~master_key ~master_salt ~label:Srtp.Label.rtp_encryption 16);
  check_string "cipher salt"
    ~expected:(hex "30CBBC08863D8C85D49DB34A9AE1")
    (Srtp.derive ~master_key ~master_salt ~label:Srtp.Label.rtp_salt 14);
  check_string "auth key"
    ~expected:(hex "CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4")
    (Srtp.derive ~master_key ~master_salt ~label:Srtp.Label.rtp_authentication 20);

  (* §B.2: counter block and keystream *)
  check_string "counter block"
    ~expected:(hex "F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000")
    (Srtp.counter ~salt:session_salt ~ssrc:0l ~index:0);
  check_string "keystream"
    ~expected:
      (hex
         "E03EAD0935C95E80E166B16DD92B4EB4\
          D23513162B02D0F72A43A2FE4A5F97AB\
          41E95B3BB0A2E8DD477901E4FCA894C0")
    (keystream ~length:48);

  (* The counter must depend on the source and the packet index. *)
  check "the counter depends on the source"
    (Srtp.counter ~salt:session_salt ~ssrc:1l ~index:0
    <> Srtp.counter ~salt:session_salt ~ssrc:0l ~index:0);
  check "the counter depends on the index"
    (Srtp.counter ~salt:session_salt ~ssrc:0l ~index:1
    <> Srtp.counter ~salt:session_salt ~ssrc:0l ~index:0);

  (* Rollover and replay, exercised through unprotect: a packet is protected
     here under a rollover counter the receiver is never told, so a wrong guess
     on its part shows up as an authentication failure rather than as silently
     wrong audio. *)
  let key = hex "00112233445566778899AABBCCDDEEFF" in
  let salt = hex "0102030405060708090A0B0C0D0E" in
  let context = Srtp.create ~master_key:key ~master_salt:salt in
  let keys =
    {
      Srtp.cipher =
        Mirage_crypto.AES.CTR.of_secret
          (Srtp.derive ~master_key:key ~master_salt:salt
             ~label:Srtp.Label.rtp_encryption Srtp.key_length);
      authentication =
        Srtp.derive ~master_key:key ~master_salt:salt
          ~label:Srtp.Label.rtp_authentication 20;
      salt =
        Srtp.derive ~master_key:key ~master_salt:salt ~label:Srtp.Label.rtp_salt
          Srtp.salt_length;
    }
  in
  let ssrc = 0x11223344l in
  let payload = "the payload" in
  let protect ~roc ~sequence =
    let header = Bytes.create 12 in
    Bytes.set_uint8 header 0 0x80;
    Bytes.set_uint8 header 1 111;
    Bytes.set_uint16_be header 2 sequence;
    Bytes.set_int32_be header 4 (Int32.of_int (sequence * 960));
    Bytes.set_int32_be header 8 ssrc;
    let header = Bytes.to_string header in
    let index = (roc * 65536) + sequence in
    let body = header ^ Srtp.cipher keys ~ssrc ~index ~data:payload in
    let roll = Bytes.create 4 in
    Bytes.set_int32_be roll 0 (Int32.of_int roc);
    body ^ Srtp.authenticate ~key:keys.authentication (body ^ Bytes.to_string roll)
  in
  let receive ~roc ~sequence =
    match Srtp.unprotect context (protect ~roc ~sequence) with
    | Ok packet -> `Payload (Rtp.Packet.parse packet).payload
    | Error e -> `Error e
  in
  check "a protected packet comes back" (receive ~roc:0 ~sequence:65534 = `Payload payload);
  check "and the next one" (receive ~roc:0 ~sequence:65535 = `Payload payload);
  (* The sequence wraps: the receiver must move to the next rollover counter
     on its own, or the tag will not match. *)
  check "the sequence wraps" (receive ~roc:1 ~sequence:0 = `Payload payload);
  check "and carries on" (receive ~roc:1 ~sequence:1 = `Payload payload);
  check "a replay is refused" (receive ~roc:1 ~sequence:1 = `Error Srtp.Replayed);
  check "a straggler from before the wrap"
    (receive ~roc:0 ~sequence:65533 = `Payload payload);
  (* A packet whose rollover counter disagrees with what the receiver inferred
     cannot authenticate. *)
  check "a wrong rollover counter is caught"
    (receive ~roc:7 ~sequence:100 = `Error Srtp.Authentication_failed);

  let packet = Bytes.of_string (protect ~roc:1 ~sequence:200) in
  Bytes.set packet 20 'X';
  check "tampering is caught"
    (Srtp.unprotect context (Bytes.to_string packet)
    = Error Srtp.Authentication_failed);
  check "a truncated packet is refused"
    (Srtp.unprotect context "\x80\x6f\x00\x01" = Error Srtp.Too_short);
  let other = Srtp.create ~master_key:(hex "FF" ^ String.sub key 1 15) ~master_salt:salt in
  check "another key does not authenticate"
    (Srtp.unprotect other (protect ~roc:1 ~sequence:300)
    = Error Srtp.Authentication_failed);

  suite "srtp sending";
  (* Protecting has no published vector of its own, so it is held against the
     packets built by hand out of the primitives that do: the same header, the
     same counter mode over the same session keys, the same tag. *)
  let sending = Srtp.sender ~master_key:key ~master_salt:salt in
  let unprotected ~sequence =
    let header = Bytes.create 12 in
    Bytes.set_uint8 header 0 0x80;
    Bytes.set_uint8 header 1 111;
    Bytes.set_uint16_be header 2 sequence;
    Bytes.set_int32_be header 4 (Int32.of_int (sequence * 960));
    Bytes.set_int32_be header 8 ssrc;
    Bytes.to_string header ^ payload
  in
  check_string "a packet is protected as the vectors say"
    ~expected:(protect ~roc:0 ~sequence:1000)
    (Srtp.protect sending (unprotected ~sequence:1000));
  (* The rollover counter is the sender's to keep, and has to move the way the
     receiver will infer that it moved. *)
  check_string "up to the wrap" ~expected:(protect ~roc:0 ~sequence:65535)
    (Srtp.protect sending (unprotected ~sequence:65535));
  check_string "and over it" ~expected:(protect ~roc:1 ~sequence:0)
    (Srtp.protect sending (unprotected ~sequence:0));
  (* A forwarder sends what the network gave it, and the network reorders; a
     straggler must not be numbered by its turn. *)
  check_string "a straggler keeps the counter its number says"
    ~expected:(protect ~roc:0 ~sequence:65534)
    (Srtp.protect sending (unprotected ~sequence:65534));
  check "and what was protected is read back"
    (Srtp.unprotect
       (Srtp.create ~master_key:key ~master_salt:salt)
       (Srtp.protect
          (Srtp.sender ~master_key:key ~master_salt:salt)
          (unprotected ~sequence:7))
    = Ok (unprotected ~sequence:7));
  check "a datagram that is not RTP is refused"
    (match Srtp.protect sending "junk" with
    | _ -> false
    | exception Invalid_argument _ -> true);

  suite "srtcp";
  (* The sending half has no published vector of its own, so it is checked
     against the receiving half, which does: the two derive the same session
     keys from one master, and a browser's stack is on the other side of the
     same agreement. *)
  let sender = Srtp.sender ~master_key:key ~master_salt:salt in
  let receiver = Srtp.create ~master_key:key ~master_salt:salt in
  let pli = Rtp.Rtcp.pli ~sender:0x11223344l ~media:0xDEADBEEFl in
  let protected = Srtp.protect_rtcp sender pli in
  check "protecting adds the index and the tag"
    (String.length protected = String.length pli + 4 + Srtp.tag_length);
  check "the header travels in the clear"
    (String.sub protected 0 8 = String.sub pli 0 8);
  check "but the rest does not"
    (String.sub protected 8 4 <> String.sub pli 8 4);
  check "and comes back" (Srtp.unprotect_rtcp receiver protected = Ok pli);
  check "the index moves on"
    (match Srtp.unprotect_rtcp receiver (Srtp.protect_rtcp sender pli) with
    | Ok packet -> packet = pli
    | Error _ -> false);
  (* Which is what keeps the counter blocks apart, and the replay window
     working: the same packet protected twice is two different datagrams. *)
  check "so the same packet twice is not a replay"
    (Srtp.protect_rtcp sender pli <> Srtp.protect_rtcp sender pli);
  let tampered = Bytes.of_string protected in
  Bytes.set tampered 9 'X';
  check "tampering is caught"
    (Srtp.unprotect_rtcp receiver (Bytes.to_string tampered)
    = Error Srtp.Authentication_failed)

let () =
  run ();
  exit_status ()

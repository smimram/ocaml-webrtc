(** The RTP header parser and the jitter buffer; the payload formats are in
    the [Test_vp8], [Test_vp9] and [Test_h264] modules beside this one. *)

open Testlib

(* A packet with two CSRCs and a header extension, so that the payload offset
   depends on both. *)
let packet =
  hex
    ("92" (* version 2, extension, 2 CSRCs *) ^ "EF" (* marker, payload type 111 *)
   ^ "1234" (* sequence *) ^ "0000C000" (* timestamp *) ^ "DEADBEEF" (* SSRC *)
   ^ "00000001" ^ "00000002" (* CSRCs *)
   ^ "BEDE0001" ^ "10AABBCC" (* one word of header extension *)
   ^ "78797A" (* payload *))

let run () =
  suite "rtp";

  let p = Rtp.Packet.parse packet in
  check "payload type" (p.payload_type = 111);
  check "marker" p.marker;
  check "sequence" (p.sequence = 0x1234);
  check "timestamp" (p.timestamp = 0xC000l);
  check "ssrc" (p.ssrc = 0xDEADBEEFl);
  check "contributing sources" (p.csrc = [ 1l; 2l ]);
  check "header extension" (p.extension = Some (0xBEDE, hex "10AABBCC"));
  check_string "payload" ~expected:(hex "78797A") p.payload;
  check "header length" (p.header_length = 12 + 8 + 8);
  check "not RTCP" (not (Rtp.Packet.is_rtcp packet));
  (* A receiver report: payload type 201 with the marker bit set reads as 73. *)
  check "a receiver report is RTCP" (Rtp.Packet.is_rtcp (hex "81C90007"));

  (* What a forwarder does: parse, alter the numbering and the source, write
     back out. Everything it did not touch has to survive the trip. *)
  check_string "a packet written back out is the packet"
    ~expected:packet (Rtp.Packet.encode p);
  let moved =
    Rtp.Packet.parse
      (Rtp.Packet.encode
         { p with sequence = 0x4321; ssrc = 1l; payload_type = 96 })
  in
  check "the fields a forwarder rewrites are rewritten"
    (moved.sequence = 0x4321 && moved.ssrc = 1l && moved.payload_type = 96);
  check "and the rest is untouched"
    (moved.marker && moved.timestamp = 0xC000l && moved.csrc = [ 1l; 2l ]
    && moved.extension = p.extension
    && moved.payload = p.payload);
  (* Dropping the extension shortens the header, which the flag has to say. *)
  let bare = Rtp.Packet.parse (Rtp.Packet.encode { p with extension = None; csrc = [] }) in
  check "a header stripped of what a peer did not negotiate is shorter"
    (bare.header_length = 12 && bare.extension = None && bare.csrc = []);
  check "an extension that is not a whole number of words is refused"
    (match Rtp.Packet.encode { p with extension = Some (0xBEDE, "abc") } with
    | _ -> false
    | exception Rtp.Packet.Invalid _ -> true);

  suite "reorder";
  let buffer = Rtp.Reorder.create ~depth:3 () in
  let push sequence = Rtp.Reorder.push buffer sequence sequence in
  check "the first packet passes straight through" (push 100 = [ 100 ]);
  check "and the next" (push 101 = [ 101 ]);
  check "a gap is held back" (push 103 = []);
  check "and released when it fills" (push 102 = [ 102; 103 ]);
  check "a duplicate is dropped" (push 102 = []);
  check "a late packet is dropped" (push 99 = []);
  (* A packet that never arrives must not stall the stream: once the buffer is
     deeper than its limit, it moves on. *)
  check "waiting for 104" (push 105 = []);
  check "still waiting" (push 106 = []);
  check "still waiting, buffer filling" (push 107 = []);
  check "giving up on 104" (push 108 = [ 105; 106; 107; 108 ]);
  check "the loss is counted" (Rtp.Reorder.lost buffer = 1);
  check "and the stream carries on" (push 109 = [ 109 ]);

  (* A stream too sparse to reach the depth is bounded by the clock instead:
     three packets a second would otherwise sit on a gap for as long as it took
     the depth to fill. *)
  let buffer = Rtp.Reorder.create ~depth:100 ~deadline:0.2 () in
  let push now sequence = Rtp.Reorder.push ~now buffer sequence sequence in
  check "the first packet passes straight through" (push 0. 200 = [ 200 ]);
  check "a gap is held back" (push 0.1 202 = []);
  check "and still, a moment later" (push 0.2 203 = []);
  check "until the deadline passes" (push 0.35 204 = [ 202; 203; 204 ]);
  check "the loss is counted" (Rtp.Reorder.lost buffer = 1);
  (* The deadline is only ever tested when something happens, so a track that
     falls silent mid-gap needs telling that time has passed. *)
  check "a second gap is held back" (push 0.4 206 = []);
  check "which no arrival will now release" (Rtp.Reorder.expire ~now:0.5 buffer = []);
  check "until its deadline passes too"
    (Rtp.Reorder.expire ~now:0.7 buffer = [ 206 ]);
  check "and then there is nothing left to expire"
    (Rtp.Reorder.expire ~now:1.0 buffer = []);

  suite "rtcp";
  (* RFC 4585 §6.3.1: version 2, feedback message type 1, payload type 206,
     two words of payload after the header word. *)
  check_string "a picture loss indication"
    ~expected:(hex "81CE0002 DEADBEEF 0000002A")
    (Rtp.Rtcp.pli ~sender:0xDEADBEEFl ~media:42l);
  check "which reads as RTCP" (Rtp.Packet.is_rtcp (Rtp.Rtcp.pli ~sender:1l ~media:2l));

  (* RFC 3550 §6.4.2: version 2, one report block, payload type 201, seven
     words after the header word. *)
  check_string "a receiver report"
    ~expected:
      (hex
         "81C90007 DEADBEEF CAFEBABE 10000005 00001234 00000040 AABBCCDD \
          00008000")
    (Rtp.Rtcp.receiver_report ~sender:0xDEADBEEFl
       [
         {
           Rtp.Rtcp.source = 0xCAFEBABEl;
           fraction_lost = 0x10;
           cumulative_lost = 5;
           extended_highest = 0x1234l;
           jitter = 0x40l;
           last_sr = 0xAABBCCDDl;
           delay_since_last_sr = 0x8000l;
         };
       ]);

  (* RFC 3550 §6.5: one chunk, payload type 202; the CNAME is item type 1 with
     its own length, and the chunk is terminated and padded with nulls. *)
  check_string "a source description"
    ~expected:(hex "81CA0003 DEADBEEF 0103616263 000000")
    (Rtp.Rtcp.source_description ~sender:0xDEADBEEFl ~cname:"abc");

  (* A sender report, then something else, so that the walk has to step over a
     packet to reach the end. The timestamp read out is the middle 32 bits of
     the NTP one. *)
  let sender_report =
    hex
      ("80C80006" ^ "11223344" (* SSRC *) ^ "0102030405060708" (* NTP *)
     ^ "00000000" (* RTP timestamp *) ^ "00000000" (* packet count *)
     ^ "00000000" (* octet count *))
  in
  let expected =
    [
      {
        Rtp.Rtcp.sender = 0x11223344l;
        ntp = 0x0102030405060708L;
        rtp_timestamp = 0l;
        packets = 0l;
        octets = 0l;
      };
    ]
  in
  check "a sender report is read"
    (Rtp.Rtcp.sender_reports sender_report = expected);
  check "the timestamp echoed back is its middle"
    (Rtp.Rtcp.compact_ntp 0x0102030405060708L = 0x03040506l);
  check "and found after one that is stepped over"
    (Rtp.Rtcp.sender_reports
       (Rtp.Rtcp.compound
          [
            Rtp.Rtcp.source_description ~sender:1l ~cname:"x"; sender_report;
          ])
    = expected);
  check "a truncated packet stops the walk"
    (Rtp.Rtcp.sender_reports (String.sub sender_report 0 20) = []);

  (* What we write is what we read: the same report, built rather than
     spelled out. *)
  check "a sender report we build reads back"
    (Rtp.Rtcp.sender_reports
       (Rtp.Rtcp.sender_report ~sender:0x11223344l ~ntp:0x0102030405060708L
          ~timestamp:0l ~packets:0l ~octets:0l)
    = expected);
  check_string "and is the packet the vector spells out" ~expected:sender_report
    (Rtp.Rtcp.sender_report ~sender:0x11223344l ~ntp:0x0102030405060708L
       ~timestamp:0l ~packets:0l ~octets:0l);

  (* An NTP timestamp of the Unix epoch is the seventy years between the two
     epochs, exactly, with nothing below the point. *)
  check "the NTP epoch is seventy years before the Unix one"
    (Rtp.Rtcp.ntp_of_time 0. = Int64.shift_left 2208988800L 32);

  check "a keyframe request names its source"
    (Rtp.Rtcp.keyframe_requests
       (Rtp.Rtcp.compound
          [
            Rtp.Rtcp.source_description ~sender:1l ~cname:"x";
            Rtp.Rtcp.pli ~sender:0xDEADBEEFl ~media:0xCAFEBABEl;
          ])
    = [ 0xCAFEBABEl ]);
  check "and a compound packet with none in it asks for nothing"
    (Rtp.Rtcp.keyframe_requests sender_report = []);

  suite "reception";
  let packet ?(ssrc = 0xCAFEBABEl) ~sequence ~timestamp () =
    {
      Rtp.Packet.padding = false;
      marker = false;
      payload_type = 111;
      sequence;
      timestamp = Int32.of_int timestamp;
      ssrc;
      csrc = [];
      extension = None;
      payload = "";
      header_length = 12;
    }
  in
  let reception = Rtp.Reception.create ~clock_rate:48000 in
  check "nothing to report before anything arrives"
    (Rtp.Reception.report ~now:0. reception = None);
  let receive now sequence timestamp =
    Rtp.Reception.receive ~now reception (packet ~sequence ~timestamp ())
  in
  receive 0. 1000 0;
  receive 0.02 1001 960;
  check "the source is the one that arrived"
    (Rtp.Reception.source reception = Some 0xCAFEBABEl);
  (match Rtp.Reception.report ~now:0.02 reception with
  | None -> check "a report once a packet has arrived" false
  | Some report ->
      check "nothing lost" (report.fraction_lost = 0 && report.cumulative_lost = 0);
      check "the highest sequence number" (report.extended_highest = 1001l);
      check "a steady stream has no jitter" (report.jitter = 0l);
      check "and no sender report to echo"
        (report.last_sr = 0l && report.delay_since_last_sr = 0l));

  (* One packet of the two expected since the last report never arrives, and
     the one that does arrives 20 ms after its timestamp says it should. *)
  receive 0.08 1003 2880;
  (match Rtp.Reception.report ~now:0.08 reception with
  | None -> check "a report after a loss" false
  | Some report ->
      check "half the interval was lost" (report.fraction_lost = 128);
      check "and counted cumulatively" (report.cumulative_lost = 1);
      (* The packet came 20 ms later than its timestamp said, which is 960
         ticks of deviation, smoothed by a sixteenth. *)
      check "the delay shows as jitter" (report.jitter = 60l));

  (* A gap is only a gap: the reordered packet still counts as arriving. *)
  receive 0.1 1002 1920;
  (match Rtp.Reception.report ~now:0.1 reception with
  | None -> check "a report after the straggler" false
  | Some report ->
      check "the straggler cancels the loss" (report.cumulative_lost = 0);
      check "and is not counted against the new interval"
        (report.fraction_lost = 0));

  let reception = Rtp.Reception.create ~clock_rate:48000 in
  let receive now sequence timestamp =
    Rtp.Reception.receive ~now reception (packet ~sequence ~timestamp ())
  in
  receive 0. 65534 0;
  receive 0.02 65535 960;
  receive 0.04 0 1920;
  receive 0.06 1 2880;
  (match Rtp.Reception.report ~now:0.06 reception with
  | None -> check "a report across the wrap" false
  | Some report ->
      check "the sequence number wrap is counted"
        (report.extended_highest = 0x10001l);
      check "and nothing looks lost across it"
        (report.fraction_lost = 0 && report.cumulative_lost = 0));

  Rtp.Reception.sender_report ~now:0.1 reception ~ntp:0xAABBCCDDl;
  (match Rtp.Reception.report ~now:0.6 reception with
  | None -> check "a report echoing a sender report" false
  | Some report ->
      check "the sender report is echoed" (report.last_sr = 0xAABBCCDDl);
      (* Half a second, in units of 1/65536 of one. *)
      check "with how long ago it arrived"
        (report.delay_since_last_sr = 32768l));
  ()

let () =
  run ();
  Test_vp8.run ();
  Test_vp9.run ();
  Test_h264.run ();
  exit_status ()
